import Foundation

// MARK: - Provider-neutral conversation

struct ToolCall {
    var id: String
    var name: String
    /// Parsed arguments; nil when the model produced arguments that aren't a JSON object.
    var input: [String: Any]?
    /// Arguments exactly as the model sent them (OpenAI passes a JSON string), echoed back verbatim.
    var rawArguments: String
}

struct ToolResult {
    var callID: String
    var content: String
    var isError: Bool
}

struct AssistantTurn {
    var text: String
    var toolCalls: [ToolCall]
    /// The untouched Anthropic `content` array when an Anthropic model produced this turn. Echoed back as-is so thinking
    /// blocks stay valid; other providers only see `text` and `toolCalls`.
    var anthropicContent: [[String: Any]]?
    var providerID: String
}

/// The conversation in a form every provider can be rendered from, so the user can switch providers mid-conversation.
enum ChatTurn {
    case user([String])
    case assistant(AssistantTurn)
    case toolResults([ToolResult])
}

enum StopReason: Equatable {
    case endTurn, toolUse, maxTokens
    case refusal(String?)
}

struct ModelReply {
    var turn: AssistantTurn
    var stop: StopReason
    /// Model that actually answered (may differ from the requested one, e.g. after a server-side fallback).
    var model: String
}

struct ToolSpec {
    let name: String
    let description: String
    let schema: [String: Any]

    /// Tool definitions are written in Anthropic's shape (`input_schema`); this reads them for any provider.
    static func from(anthropic definitions: [[String: Any]]) -> [ToolSpec] {
        definitions.compactMap { d in
            guard let name = d["name"] as? String, let schema = d["input_schema"] as? [String: Any] else { return nil }
            return ToolSpec(name: name, description: d["description"] as? String ?? "", schema: schema)
        }
    }
}

@MainActor
protocol ModelClient {
    func send(system: [String], turns: [ChatTurn], tools: [ToolSpec], maxTokens: Int) async throws -> ModelReply
    func listModels() async throws -> [String]
}

@MainActor
func makeClient(for provider: ProviderConfig) -> ModelClient {
    switch provider.kind {
    case .anthropic: AnthropicClient(provider: provider)
    case .openAICompatible: OpenAIClient(provider: provider)
    }
}

// MARK: - HTTP

struct ProviderError: LocalizedError {
    let provider: String
    let status: Int
    let message: String

    var errorDescription: String? {
        switch status {
        case 401, 403: "\(provider) rejected the API key (\(status)). Check it in Settings → Providers."
        case 404: "\(provider): not found (404). Check the base URL and model name. \(message)"
        case 429: "\(provider) is rate limiting requests. Try again in a moment."
        case 529: "\(provider) is overloaded. Try again in a moment."
        case 0: "\(provider): \(message)"
        default: "\(provider) error \(status): \(message)"
        }
    }
}

enum HTTP {
    /// JSON request with retries for transient failures (408/409/429/5xx and connection drops), honoring `retry-after`.
    static func json(_ method: String, url: URL, headers: [String: String], body: [String: Any]? = nil,
                     provider: String, timeout: TimeInterval = 600) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let parsed = try? JSONSerialization.jsonObject(with: data)
                if (200..<300).contains(status), let json = parsed as? [String: Any] { return json }

                let retryable = status == 408 || status == 409 || status == 429 || status >= 500
                if retryable, attempt < 2 {
                    let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? pow(2, Double(attempt + 1))
                    try await Task.sleep(for: .seconds(min(wait, 30)))
                    attempt += 1
                    continue
                }
                throw ProviderError(provider: provider, status: status, message: errorMessage(parsed, data, status: status))
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .notConnectedToInternet]
                if transient.contains(error.code), attempt < 2 {
                    attempt += 1
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                throw ProviderError(provider: provider, status: 0, message: describe(error, url: url))
            }
        }
    }

    private static func errorMessage(_ parsed: Any?, _ data: Data, status: Int) -> String {
        if let json = parsed as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
            if let detail = json["detail"] as? String { return detail }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : String(text.prefix(300))
    }

    private static func describe(_ error: URLError, url: URL) -> String {
        let host = url.host ?? url.absoluteString
        switch error.code {
        case .cannotConnectToHost: return "couldn't connect to \(host)\(url.port.map { ":\($0)" } ?? ""). Is the server running?"
        case .cannotFindHost, .dnsLookupFailed: return "couldn't find the server \(host). Check the base URL."
        case .timedOut: return "the request to \(host) timed out."
        case .notConnectedToInternet: return "you appear to be offline."
        case .appTransportSecurityRequiresSecureConnection: return "plain HTTP to \(host) was blocked. Use https://."
        default: return error.localizedDescription
        }
    }

    /// Joins a base URL and a path without doubling or dropping slashes.
    static func endpoint(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path), url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw ProviderError(provider: "Provider", status: 0, message: "“\(base)” isn't a valid http(s) base URL.")
        }
        return url
    }
}

/// Tool-call ids cross providers; Anthropic only accepts `[A-Za-z0-9_-]{1,64}`, and some local servers send none.
func normalizedToolID(_ id: String?) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    let cleaned = String((id ?? "").filter { allowed.contains($0) }.prefix(64))
    return cleaned.isEmpty ? "call_" + ShortID.make(16) : cleaned
}

func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}
