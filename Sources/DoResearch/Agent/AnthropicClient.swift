import Foundation

/// Claude Messages API over raw HTTP (there is no official Swift SDK). Also works with Anthropic-compatible gateways.
@MainActor
struct AnthropicClient: ModelClient {
    let provider: ProviderConfig

    /// Prompt caching and server-side refusal fallback are first-party features; gateways may reject the fields.
    private var isFirstParty: Bool { provider.host == "api.anthropic.com" }

    /// Server-side fallback exists on the Claude API for Opus 5.5 and Sonnet 5.5 (not Haiku 5.5).
    private var supportsServerFallback: Bool {
        isFirstParty && ["claude-opus-5-5", "claude-sonnet-5-5"].contains(provider.model)
    }

    private func url(_ path: String) throws -> URL {
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return try HTTP.endpoint(base, path)
    }

    private var headers: [String: String] {
        var h = ["anthropic-version": "2023-06-01"]
        if let key = provider.apiKey { h["x-api-key"] = key }
        return h
    }

    func send(system: [String], turns: [ChatTurn], tools: [ToolSpec], maxTokens: Int) async throws -> ModelReply {
        var body: [String: Any] = [
            "model": provider.model,
            "max_tokens": maxTokens,
            "system": system.map { ["type": "text", "text": $0] },
            "messages": Self.render(turns),
            "tools": tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] },
        ]
        if let effort = provider.effort { body["output_config"] = ["effort": effort] }
        var headers = headers
        if isFirstParty { body["cache_control"] = ["type": "ephemeral"] }
        if supportsServerFallback {
            body["fallbacks"] = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let json = try await HTTP.json("POST", url: url("/v1/messages"), headers: headers, body: body, provider: provider.name)
        return Self.parse(json, providerID: provider.id, requestedModel: provider.model)
    }

    func listModels() async throws -> [String] {
        let json = try await HTTP.json("GET", url: url("/v1/models?limit=1000"), headers: headers, provider: provider.name, timeout: 30)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    // MARK: Conversion

    static func render(_ turns: [ChatTurn]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        func appendUser(_ blocks: [[String: Any]]) {
            // Anthropic requires alternating roles, so adjacent user content merges into one message.
            if var last = messages.last, last["role"] as? String == "user", var existing = last["content"] as? [[String: Any]] {
                existing += blocks
                last["content"] = existing
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": "user", "content": blocks])
            }
        }
        for turn in turns {
            switch turn {
            case .user(let texts):
                appendUser(texts.map { ["type": "text", "text": $0] })
            case .toolResults(let results):
                appendUser(results.map { r in
                    var block: [String: Any] = ["type": "tool_result", "tool_use_id": r.callID, "content": r.content]
                    if r.isError { block["is_error"] = true }
                    return block
                })
            case .assistant(let a):
                messages.append(["role": "assistant", "content": a.anthropicContent ?? content(for: a)])
            }
        }
        return messages
    }

    /// Rebuilds Anthropic content for a turn another provider produced.
    private static func content(for a: AssistantTurn) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let text = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
        for call in a.toolCalls {
            blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": call.input ?? [:]])
        }
        return blocks.isEmpty ? [["type": "text", "text": "(no response)"]] : blocks
    }

    static func parse(_ json: [String: Any], providerID: String, requestedModel: String) -> ModelReply {
        let content = json["content"] as? [[String: Any]] ?? []
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let calls = content.filter { $0["type"] as? String == "tool_use" }.map { block -> ToolCall in
            let input = block["input"] as? [String: Any]
            return ToolCall(id: block["id"] as? String ?? normalizedToolID(nil), name: block["name"] as? String ?? "",
                            input: input, rawArguments: jsonString(input ?? [:]))
        }
        let stop: StopReason
        switch json["stop_reason"] as? String {
        case "refusal": stop = .refusal((json["stop_details"] as? [String: Any])?["explanation"] as? String)
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        default: stop = calls.isEmpty ? .endTurn : .toolUse
        }
        return ModelReply(
            turn: AssistantTurn(text: text, toolCalls: calls, anthropicContent: content, providerID: providerID),
            stop: stop,
            model: json["model"] as? String ?? requestedModel
        )
    }
}
