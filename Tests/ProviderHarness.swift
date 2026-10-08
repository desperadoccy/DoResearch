// Provider conversion and networking checks against Tests/mock/mock_server.py: scripts/test.sh
import Foundation

@MainActor
enum ProviderHarness {
    static func run(expect: (Bool, String) -> Void) async {
        print("\n— providers: conversion —")
        let calls = [ToolCall(id: "call_1", name: "list_items", input: ["kind": "coding"], rawArguments: "{\"kind\":\"coding\"}")]
        let thinking: [[String: Any]] = [["type": "thinking", "thinking": "", "signature": "S"],
                                         ["type": "tool_use", "id": "toolu_1", "name": "get_item", "input": ["id": "x"]]]
        let turns: [ChatTurn] = [
            .user(["<app_context>ctx</app_context>", "hello"]),
            .assistant(AssistantTurn(text: "", toolCalls: calls, anthropicContent: nil, providerID: "oai")),
            .toolResults([ToolResult(callID: "call_1", content: "[]", isError: false)]),
            .user(["next"]),
            .assistant(AssistantTurn(text: "", toolCalls: [ToolCall(id: "toolu_1", name: "get_item", input: ["id": "x"], rawArguments: "{\"id\":\"x\"}")],
                                     anthropicContent: thinking, providerID: "claude")),
            .toolResults([ToolResult(callID: "toolu_1", content: "nope", isError: true)]),
        ]

        let a = AnthropicClient.render(turns)
        expect(a.map { $0["role"] as! String } == ["user", "assistant", "user", "assistant", "user"], "Anthropic: tool results merge with the next user message")
        let merged = a[2]["content"] as! [[String: Any]]
        expect(merged.map { $0["type"] as! String } == ["tool_result", "text"], "Anthropic: merged message is [tool_result, text]")
        let rebuilt = a[1]["content"] as! [[String: Any]]
        expect(rebuilt.first?["type"] as? String == "tool_use" && rebuilt.first?["id"] as? String == "call_1", "Anthropic: OpenAI turn rebuilt as tool_use")
        expect((a[3]["content"] as! [[String: Any]]).first?["signature"] as? String == "S", "Anthropic: its own turns echo verbatim (thinking kept)")
        expect((a[4]["content"] as! [[String: Any]]).first?["is_error"] as? Bool == true, "Anthropic: error flag on tool_result")

        let o = OpenAIClient.render(turns)
        expect(o.map { $0["role"] as! String } == ["user", "assistant", "tool", "user", "assistant", "tool"], "OpenAI: role sequence")
        expect(o[0]["content"] as? String == "<app_context>ctx</app_context>\n\nhello", "OpenAI: user parts joined")
        expect(o[1]["content"] is NSNull, "OpenAI: tool-only assistant has null content")
        let fn = ((o[1]["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any])
        expect(fn["arguments"] as? String == "{\"kind\":\"coding\"}", "OpenAI: arguments echoed verbatim")
        expect(o[2]["tool_call_id"] as? String == "call_1", "OpenAI: tool result linked by id")
        expect(!(o.description.contains("signature")), "OpenAI: Anthropic thinking never leaks into other providers")

        let reply = try? OpenAIClient.parse([
            "model": "m",
            "choices": [["finish_reason": "stop", "message": [
                "content": "<think>plan</think>Done.",
                "tool_calls": [["id": "weird id!", "type": "function", "function": ["name": "add_log", "arguments": "{not json"]],
                               ["type": "function", "function": ["name": "list_items", "arguments": ""]]],
            ]]],
        ], providerID: "p", requestedModel: "m", providerName: "P")
        expect(reply?.stop == .toolUse, "OpenAI: tool calls win over finish_reason stop")
        expect(reply?.turn.text == "Done.", "OpenAI: <think> stripped from text")
        expect(reply?.turn.toolCalls[0].input == nil, "OpenAI: malformed arguments flagged, not guessed")
        expect(reply?.turn.toolCalls[0].id == "weirdid", "OpenAI: tool id sanitized for Anthropic")
        expect(reply?.turn.toolCalls[1].input?.isEmpty == true && reply?.turn.toolCalls[1].id.hasPrefix("call_") == true,
               "OpenAI: empty arguments → {} and missing id generated")
        let rendered = OpenAIClient.render([.assistant(reply!.turn)])
        let args = ((rendered[0]["tool_calls"] as! [[String: Any]])[0]["function"] as! [String: Any])["arguments"] as? String
        expect(args == "{}", "OpenAI: malformed arguments replaced with {} when echoed")
        let refusal = try? OpenAIClient.parse(["choices": [["finish_reason": "stop", "message": ["content": NSNull(), "refusal": "no"]]]],
                                              providerID: "p", requestedModel: "m", providerName: "P")
        expect(refusal?.stop == .refusal("no"), "OpenAI: refusal detected")
        let err = (try? OpenAIClient.parse(["error": ["message": "quota"]], providerID: "p", requestedModel: "m", providerName: "P")) == nil
        expect(err, "OpenAI: error body with HTTP 200 throws")

        let ar = AnthropicClient.parse(["model": "claude-opus-4-8", "stop_reason": "refusal", "content": [],
                                        "stop_details": ["type": "refusal", "explanation": "x"]], providerID: "a", requestedModel: "claude-opus-5-5")
        expect(ar.stop == .refusal("x") && ar.model == "claude-opus-4-8", "Anthropic: refusal + served-by model")

        // MARK: Networking against the mock server
        print("\n— providers: mock server —")
        guard let port = ProcessInfo.processInfo.environment["MOCK_PORT"] else {
            expect(false, "MOCK_PORT not set; run via scripts/test.sh")
            return
        }
        let base = "http://127.0.0.1:\(port)"
        let oai = ProviderConfig(id: "t-oai", name: "MockOAI", kind: .openAICompatible, baseURL: base + "/v1/", model: "mock-gpt")
        let ant = ProviderConfig(id: "t-ant", name: "MockAnthropic", kind: .anthropic, baseURL: base + "/v1", model: "mock-claude", effort: "low")

        let models = try? await makeClient(for: oai).listModels()
        expect(models == ["mock-gpt-a", "mock-gpt-b"], "OpenAI: /models listed and sorted (got \(models ?? []))")
        let antModels = try? await makeClient(for: ant).listModels()
        expect(antModels == ["mock-claude"], "Anthropic: /v1/models listed (base URL with /v1 normalized)")

        let t1 = await AgentSession.test(oai)
        expect(t1.level == .ok, "OpenAI: connection test passes with tool call (\(t1.message))")
        let t2 = await AgentSession.test(ant)
        expect(t2.level == .ok, "Anthropic: connection test passes (\(t2.message))")
        var bad = oai
        bad.model = "bad-model"
        let t3 = await AgentSession.test(bad)
        expect(t3.level == .failure && t3.message.contains("not found"), "Bad model reported clearly (\(t3.message))")
        let dead = ProviderConfig(id: "t-dead", name: "Dead", kind: .openAICompatible, baseURL: "http://127.0.0.1:9/v1", model: "x")
        let t4 = await AgentSession.test(dead)
        expect(t4.level == .failure && t4.message.contains("Is the server running"), "Unreachable server explained (\(t4.message))")

        // Full agent loop, switching provider mid-conversation.
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-prov-\(UUID().uuidString).sqlite")
        let store = Store(url: dbURL)
        store.createProject(Project(id: "", name: "Mock Project"))
        let suite = "dr-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let ps = ProviderStore(defaults: defaults, migrateLegacy: false)
        // Use throwaway providers only: the default one has the real "anthropic" id and Keychain entry.
        let a2 = ps.add(from: ProviderPreset.all[0])
        ps.update(ProviderConfig(id: a2.id, name: "MockAnthropic", kind: .anthropic, baseURL: base, model: "mock-claude"))
        ps.remove(ps.providers[0].id == a2.id ? ps.providers[1].id : ps.providers[0].id, deletingKey: false)
        let o2 = ps.add(from: ProviderPreset.all.first { $0.id == "custom" }!)
        ps.update(ProviderConfig(id: o2.id, name: "MockOAI", kind: .openAICompatible, baseURL: base + "/v1", model: "mock-gpt"))
        let session = AgentSession(store: store, providers: ps)
        precondition(ps.providers.allSatisfy { $0.id != "anthropic" })
        ps.setKey("sk-mock-anthropic", for: a2.id)
        defer { ps.setKey("", for: a2.id) }

        ps.activeID = o2.id
        session.send("What projects do I have?")
        while session.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        expect(session.entries.contains { $0.role == .tool && $0.text.contains("project") }, "OpenAI loop ran list_projects")
        expect(session.entries.last?.text.contains("Mock Project") == true, "OpenAI loop answered from the tool result")

        ps.activeID = ps.providers[0].id
        session.send("And now?")
        while session.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        expect(session.entries.contains { $0.role == .notice && $0.text.contains("Switched to MockAnthropic") }, "switch notice shown")
        expect(session.entries.last?.text.hasPrefix("Claude saw:") == true, "Anthropic continued the same conversation")

        ps.activeID = o2.id
        session.send("Back to OpenAI")
        while session.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        expect(session.entries.last?.text.hasPrefix("Saw tool result") == true, "switched back to OpenAI")

        // Inspect what went over the wire.
        let logPath = ProcessInfo.processInfo.environment["MOCK_LOG"]! + "/requests.jsonl"
        let lines = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n") ?? []
        let requests = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let claudeCalls = requests.filter { $0["path"] as? String == "/v1/messages" && (($0["body"] as? [String: Any])?["model"] as? String) == "mock-claude" }
        let lastClaude = claudeCalls.last?["body"] as? [String: Any]
        let roles = (lastClaude?["messages"] as? [[String: Any]])?.map { $0["role"] as! String } ?? []
        var alternates = true
        for (x, y) in zip(roles, roles.dropFirst()) where x == y { alternates = false }
        expect(alternates && roles.first == "user", "Anthropic request alternates roles after a provider switch (\(roles))")
        expect(lastClaude?["cache_control"] == nil && lastClaude?["fallbacks"] == nil, "first-party-only fields omitted for other hosts")
        let headers = claudeCalls.last?["headers"] as? [String: String]
        expect(headers?["anthropic-version"] == "2023-06-01" && headers?["x-api-key"] == "sk-mock-anthropic",
               "Anthropic version + key headers sent")

        let oaiCalls = requests.filter { $0["path"] as? String == "/v1/chat/completions" && (($0["body"] as? [String: Any])?["model"] as? String) == "mock-gpt" }
        let lastOAI = oaiCalls.last?["body"] as? [String: Any]
        let oMsgs = lastOAI?["messages"] as? [[String: Any]] ?? []
        expect(oMsgs.first?["role"] as? String == "system", "OpenAI request starts with system message")
        expect(!String(describing: oMsgs).contains("sig-"), "Anthropic thinking signatures never sent to OpenAI")
        expect(lastOAI?["max_tokens"] == nil && lastOAI?["reasoning_effort"] == nil, "OpenAI request omits optional fields")
        let oHeaders = oaiCalls.last?["headers"] as? [String: String]
        expect(oHeaders?["Authorization"] == nil, "no Authorization header without a key")

        // Persistence.
        let reloaded = ProviderStore(defaults: defaults, migrateLegacy: false)
        expect(reloaded.providers.count == 2 && reloaded.activeID == o2.id, "providers and active choice persist")
        reloaded.select(reloaded.providers[0].id, model: "mock-claude-2")
        expect(reloaded.active?.model == "mock-claude-2" && reloaded.active?.switcherModels.first == "mock-claude-2", "select() switches provider and model")
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dbURL)
    }
}
