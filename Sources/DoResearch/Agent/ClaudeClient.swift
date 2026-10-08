import Foundation

/// Raw-HTTP client for the Claude Messages API (there is no official Swift SDK).
struct ClaudeClient {
    let apiKey: String
    let model: String
    let effort: String

    static let models: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ]
    static let defaultModel = "claude-opus-5-5"
    static let efforts = ["low", "medium", "high", "xhigh"]
    static let defaultEffort = "medium"

    struct APIError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? {
            switch status {
            case 401: "The API key was rejected. Check it in Settings (⌘,)."
            case 429: "Rate limited by the API. Try again in a moment."
            case 529: "The API is overloaded. Try again in a moment."
            default: "API error \(status): \(message)"
            }
        }
    }

    /// Server-side refusal fallback is available on the Claude API for Opus 5.5 and Sonnet 5.5, not Haiku 5.5.
    private var supportsServerFallback: Bool { model == "claude-opus-5-5" || model == "claude-sonnet-5-5" }

    func createMessage(system: [[String: Any]], messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": messages,
            "tools": tools,
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if supportsServerFallback {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if status == 200, let json { return json }

                let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                    ?? String(data: data, encoding: .utf8) ?? "Unknown error"
                let retryable = status == 408 || status == 409 || status == 429 || status >= 500
                if retryable, attempt < 2 {
                    let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                    try await Task.sleep(for: .seconds(retryAfter ?? pow(2, Double(attempt + 1))))
                    attempt += 1
                    continue
                }
                throw APIError(status: status, message: message)
            } catch let error as URLError where attempt < 2 && error.code != .cancelled {
                attempt += 1
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
    }
}
