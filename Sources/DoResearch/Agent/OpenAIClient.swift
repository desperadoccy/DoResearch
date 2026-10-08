import Foundation

/// Any server that speaks the OpenAI Chat Completions API with function calling:
/// OpenAI, OpenRouter, DeepSeek, Ollama, LM Studio, vLLM, llama.cpp, and similar.
@MainActor
struct OpenAIClient: ModelClient {
    let provider: ProviderConfig

    private var headers: [String: String] {
        var h: [String: String] = [:]
        if let key = provider.apiKey { h["Authorization"] = "Bearer \(key)" }
        if provider.host == "openrouter.ai" { h["X-Title"] = "DoResearch" }
        return h
    }

    func send(system: [String], turns: [ChatTurn], tools: [ToolSpec], maxTokens: Int) async throws -> ModelReply {
        // No token cap is sent: OpenAI's reasoning models reject `max_tokens`, and servers apply sensible defaults.
        var body: [String: Any] = [
            "model": provider.model,
            "messages": [["role": "system", "content": system.joined(separator: "\n\n")]] + Self.render(turns),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
            }
        }
        if let effort = provider.reasoningEffort { body["reasoning_effort"] = effort }
        let json = try await HTTP.json("POST", url: HTTP.endpoint(provider.baseURL, "/chat/completions"),
                                       headers: headers, body: body, provider: provider.name)
        return try Self.parse(json, providerID: provider.id, requestedModel: provider.model, providerName: provider.name)
    }

    func listModels() async throws -> [String] {
        let json = try await HTTP.json("GET", url: HTTP.endpoint(provider.baseURL, "/models"), headers: headers,
                                       provider: provider.name, timeout: 30)
        let ids = (json["data"] as? [[String: Any]] ?? json["models"] as? [[String: Any]] ?? [])
            .compactMap { ($0["id"] ?? $0["name"]) as? String }
        return ids.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Conversion

    static func render(_ turns: [ChatTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for turn in turns {
            switch turn {
            case .user(let texts):
                messages.append(["role": "user", "content": texts.joined(separator: "\n\n")])
            case .assistant(let a):
                var m: [String: Any] = ["role": "assistant"]
                let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                m["content"] = text.isEmpty && !a.toolCalls.isEmpty ? NSNull() : text
                if !a.toolCalls.isEmpty {
                    m["tool_calls"] = a.toolCalls.map { call in
                        // Servers re-parse arguments for their chat templates, so never echo malformed JSON.
                        ["id": call.id, "type": "function",
                         "function": ["name": call.name, "arguments": call.input == nil ? "{}" : call.rawArguments]]
                    }
                }
                messages.append(m)
            case .toolResults(let results):
                messages += results.map { ["role": "tool", "tool_call_id": $0.callID, "content": $0.content] }
            }
        }
        return messages
    }

    static func parse(_ json: [String: Any], providerID: String, requestedModel: String, providerName: String) throws -> ModelReply {
        // Some gateways report failures with HTTP 200 and an error body.
        if let error = json["error"] as? [String: Any] {
            throw ProviderError(provider: providerName, status: (error["code"] as? Int) ?? 0,
                                message: error["message"] as? String ?? "Unknown error")
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw ProviderError(provider: providerName, status: 0, message: "The response had no choices.")
        }

        let text = stripThinking(textContent(message["content"]))
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> ToolCall? in
            guard let function = raw["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            let arguments: String
            var input: [String: Any]?
            if let s = function["arguments"] as? String {
                arguments = s
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                input = trimmed.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
            } else if let object = function["arguments"] as? [String: Any] {
                input = object
                arguments = jsonString(object)
            } else {
                input = [:]
                arguments = "{}"
            }
            return ToolCall(id: normalizedToolID(raw["id"] as? String), name: name, input: input, rawArguments: arguments)
        }

        let stop: StopReason
        let finish = choice["finish_reason"] as? String
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            stop = .refusal(refusal)
        } else if finish == "content_filter" {
            stop = .refusal(nil)
        } else if finish == "length" {
            stop = .maxTokens
        } else {
            // Several servers report "stop" even when they return tool calls.
            stop = calls.isEmpty ? .endTurn : .toolUse
        }
        return ModelReply(turn: AssistantTurn(text: text, toolCalls: calls, anthropicContent: nil, providerID: providerID),
                          stop: stop, model: json["model"] as? String ?? requestedModel)
    }

    private static func textContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        return ""
    }

    /// Open reasoning models (DeepSeek-R1, Qwen, …) served locally often inline `<think>…</think>` in the answer.
    static func stripThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
