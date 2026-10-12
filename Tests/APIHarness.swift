// Local task API checks (docs/API.md): request handling against a scratch store, then a real HTTP round trip.
import Foundation

@MainActor
enum APIHarness {
    static func run(expect: (Bool, String) -> Void) async {
        print("\n— local API —")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-api-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("doresearch.sqlite")
        let store = Store(url: url)
        let api = TaskAPI(store: store, token: "secret")

        func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
                  token: String? = "secret") -> (Int, [String: Any]) {
            var headers: [String: String] = [:]
            if let token { headers["authorization"] = "Bearer \(token)" }
            let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let r = api.handle(APIRequest(method: method, path: path, query: query, headers: headers, body: data))
            return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
        }
        func code(_ json: [String: Any]) -> String? { (json["error"] as? [String: Any])?["code"] as? String }
        func errorField(_ json: [String: Any]) -> String? { (json["error"] as? [String: Any])?["field"] as? String }

        let project = store.createProject(Project(id: "", name: "Sparse Attention"))
        let exp = store.createItem(Item(id: "", title: "Ablation: sparsity 0.9", kind: .experiment, status: .todo,
                                        projectID: project.id, setup: "bs=64"))
        _ = store.createItem(Item(id: "", title: "Write intro", kind: .writing, projectID: project.id))

        // Auth
        expect(call("GET", "/v1/health", token: nil).0 == 200, "health needs no token")
        let noAuth = call("GET", "/v1/tasks", token: nil)
        expect(noAuth.0 == 401 && code(noAuth.1) == "unauthorized", "missing token → 401 unauthorized")
        expect(code(call("GET", "/v1/tasks", token: "wrong").1) == "unauthorized", "wrong token → unauthorized")

        // Statuses and projects
        let statuses = (call("GET", "/v1/statuses").1["statuses"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        expect(statuses == ["Inbox", "Planned", "Running", "Analyzing", "Blocked", "Concluded", "Dropped"], "documented status names")
        let projects = call("GET", "/v1/projects").1["projects"] as? [[String: Any]]
        expect(projects?.first?["id"] as? String == project.id && projects?.first?["name"] as? String == "Sparse Attention", "list_projects")

        // Reading
        let (getStatus, got) = call("GET", "/v1/tasks/\(exp.id)")
        let task = got["task"] as? [String: Any] ?? [:]
        expect(getStatus == 200 && task["status"] as? String == "Planned" && task["setup"] as? String == "bs=64"
               && task["revision"] as? Int == 1 && task["progress_log"] is [[String: Any]], "get_task returns fields, revision, log")
        let missing = call("GET", "/v1/tasks/nope")
        expect(missing.0 == 404 && code(missing.1) == "task_not_found", "missing task → 404 task_not_found")
        expect(code(call("GET", "/v1/tasks", query: ["project_id": "nope"]).1) == "project_not_found", "unknown project filter → project_not_found")

        // Updating
        let (patchStatus, patched) = call("PATCH", "/v1/tasks/\(exp.id)", body: [
            "expected_revision": 1,
            "fields": ["status": "running", "compute": "4×A100", "chat_ids": ["codex-1", "codex-1"],
                       "metrics": [["name": "ppl", "value": 18.9]]],
        ])
        let after = patched["task"] as? [String: Any] ?? [:]
        expect(patchStatus == 200 && after["status"] as? String == "Running" && after["compute"] as? String == "4×A100"
               && after["setup"] as? String == "bs=64" && after["revision"] as? Int == 2, "update_task changes given fields only, bumps revision")
        expect(after["chat_ids"] as? [String] == ["codex-1"], "chat ids deduplicated")
        expect(Set(patched["changed"] as? [String] ?? []) == ["status", "compute", "chat_ids", "metrics"], "response lists changed fields")
        expect(store.item(exp.id)?.runStartedAt != nil, "API status change starts the run like the UI does")
        expect(store.logs(forItem: exp.id).contains { $0.author == .api && $0.kind == "status" }, "API changes logged with author api")

        let byChat = call("GET", "/v1/tasks", query: ["chat_id": "codex-1"]).1["tasks"] as? [[String: Any]]
        expect(byChat?.count == 1 && byChat?.first?["id"] as? String == exp.id, "list_tasks by chat id")
        let byTitle = call("GET", "/v1/tasks", query: ["title": "ABLATION", "project_id": project.id]).1["tasks"] as? [[String: Any]]
        expect(byTitle?.count == 1, "list_tasks by title (case-insensitive) and project")

        // Revision conflicts, including edits made in the app
        var edited = store.item(exp.id)!
        edited.notes = "edited in the app"
        store.updateItem(edited)
        let conflict = call("PATCH", "/v1/tasks/\(exp.id)", body: ["expected_revision": 2, "fields": ["notes": "from codex"]])
        let conflictError = conflict.1["error"] as? [String: Any]
        expect(conflict.0 == 409 && code(conflict.1) == "revision_conflict" && conflictError?["current_revision"] as? Int == 3,
               "stale expected_revision → 409 revision_conflict with current revision")
        expect(store.item(exp.id)?.notes == "edited in the app", "conflicting write leaves the newer edit in place")

        // Invalid input
        let chatStatus = call("PATCH", "/v1/tasks/\(exp.id)", body: ["fields": ["status": "completed"]])
        expect(chatStatus.0 == 422 && code(chatStatus.1) == "invalid_field" && errorField(chatStatus.1) == "status",
               "chat-style status rejected as invalid_field")
        expect(errorField(call("PATCH", "/v1/tasks/\(exp.id)", body: ["fields": ["chat_status": "done"]]).1) == "chat_status", "unknown field named")
        expect(errorField(call("PATCH", "/v1/tasks/\(exp.id)", body: ["fields": ["title": ""]]).1) == "title", "empty title rejected")
        expect(errorField(call("PATCH", "/v1/tasks/\(exp.id)", body: ["status": "Running"]).1) == "status", "fields outside `fields` rejected")
        expect(errorField(call("GET", "/v1/tasks", query: ["chatId": "x"]).1) == "chatId", "unknown query parameter rejected")
        expect(code(call("PATCH", "/v1/tasks/\(exp.id)").1) == "bad_request", "missing body → bad_request")
        expect(store.item(exp.id)?.revision == 3, "rejected requests change nothing")

        // Progress log
        let entry: [String: Any] = ["text": "Epoch 3: ppl 19.2", "source_chat_id": "codex-1", "idempotency_key": "k1"]
        let (appendStatus, appended) = call("POST", "/v1/tasks/\(exp.id)/progress", body: entry)
        expect(appendStatus == 201 && appended["duplicate"] as? Bool == false && appended["revision"] as? Int == 4, "append_progress_log → 201, bumps revision")
        let (replayStatus, replayed) = call("POST", "/v1/tasks/\(exp.id)/progress", body: entry)
        expect(replayStatus == 200 && replayed["duplicate"] as? Bool == true && replayed["revision"] as? Int == 4
               && (replayed["entry"] as? [String: Any])?["id"] as? String == (appended["entry"] as? [String: Any])?["id"] as? String,
               "replayed idempotency key returns the original entry")
        expect(store.logs(forItem: exp.id).filter { $0.idempotencyKey == "k1" }.count == 1, "no duplicate entry stored")
        let reused = call("POST", "/v1/tasks/\(exp.id)/progress", body: ["text": "different", "source_chat_id": "codex-1", "idempotency_key": "k1"])
        expect(reused.0 == 409 && code(reused.1) == "idempotency_conflict", "key reused for other content → idempotency_conflict")
        expect(errorField(call("POST", "/v1/tasks/\(exp.id)/progress", body: ["text": "x", "idempotency_key": "k2"]).1) == "source_chat_id",
               "source_chat_id required")
        let log = (call("GET", "/v1/tasks/\(exp.id)").1["task"] as? [String: Any])?["progress_log"] as? [[String: Any]]
        expect(log?.first?["source_chat_id"] as? String == "codex-1" && log?.first?["author"] as? String == "api", "log entry keeps its source chat")

        // Persistence
        let reopened = Store(url: url)
        let back = reopened.item(exp.id)
        expect(back?.revision == 4 && back?.chatIDs == ["codex-1"] && back?.compute == "4×A100", "API changes persist across reopen")
        expect(reopened.logs(forItem: exp.id).contains { $0.sourceChatID == "codex-1" && $0.idempotencyKey == "k1" }, "log source persists")

        // Copies don't take over the original's chat link.
        let dup = store.duplicate([exp.id]).first
        expect(store.item(dup)?.chatIDs == [], "duplicates drop linked chats")

        await http(store: store, dir: dir, expect: expect, taskID: exp.id)
        try? FileManager.default.removeItem(at: dir)

        // MARK: Migration from schema v4 adds revisions and log sources.
        let url6 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-harness-\(UUID().uuidString).sqlite")
        do {
            let db = try Database(url: url6)
            try db.execute("DROP INDEX idx_logs_idempotency")
            for column in ["revision", "chat_ids"] { try db.execute("ALTER TABLE items DROP COLUMN \(column)") }
            for column in ["source_chat_id", "idempotency_key"] { try db.execute("ALTER TABLE logs DROP COLUMN \(column)") }
            try db.execute("PRAGMA user_version = 4")
            let now = Date().timeIntervalSince1970
            try db.execute("INSERT INTO items (id, title, kind, status, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                           ["old", "Old item", "experiment", "todo", now, now])
        } catch { expect(false, "set up v4 database: \(error)") }
        let s6 = Store(url: url6)
        expect(s6.item("old")?.revision == 1 && s6.item("old")?.chatIDs == [], "v4 → v5 starts items at revision 1")
        try? FileManager.default.removeItem(at: url6)
    }

    /// Starts the real listener on a random port and talks to it with URLSession.
    private static func http(store: Store, dir: URL, expect: (Bool, String) -> Void, taskID: String) async {
        let suite = "dr-api-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let port = Int.random(in: 40000...60000)
        defaults.set(port, forKey: "api.port")
        let file = dir.appendingPathComponent("api.json")
        let server = APIServer(store: store, defaults: defaults, connectionFileURL: file)
        expect(server.state == .stopped, "API is off by default")
        server.setEnabled(true)
        for _ in 0..<50 where server.state != .running { try? await Task.sleep(nanoseconds: 50_000_000) }
        expect(server.state == .running, "server listening on 127.0.0.1:\(port)")

        let perms = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
        expect(perms == 0o600, "connection file is owner-only")
        let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        let token = info?["token"] as? String ?? ""
        expect(info?["base_url"] as? String == "http://127.0.0.1:\(port)/v1" && token.hasPrefix("dr_"), "connection file has base URL and token")

        func send(_ method: String, _ path: String, token: String?, body: Any? = nil) async -> (Int, [String: Any]) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1\(path)")!)
            req.httpMethod = method
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body {
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }

        expect(await send("GET", "/tasks", token: nil).0 == 401, "HTTP: no token → 401")
        let (s1, got) = await send("GET", "/tasks/\(taskID)", token: token)
        let revision = (got["task"] as? [String: Any])?["revision"] as? Int ?? -1
        expect(s1 == 200 && revision > 0, "HTTP: get_task")
        let (s2, patched) = await send("PATCH", "/tasks/\(taskID)", token: token,
                                       body: ["expected_revision": revision, "fields": ["status": "Analyzing"]])
        expect(s2 == 200 && (patched["task"] as? [String: Any])?["status"] as? String == "Analyzing" && store.item(taskID)?.status == .waiting,
               "HTTP: update_task reaches the store the UI reads")
        expect(await send("PATCH", "/tasks/\(taskID)", token: token, body: ["expected_revision": revision, "fields": ["notes": "x"]]).0 == 409,
               "HTTP: revision conflict → 409")
        expect(await send("DELETE", "/tasks/\(taskID)", token: token).0 == 405, "HTTP: unsupported method → 405")

        server.regenerateToken()
        expect(await send("GET", "/tasks", token: token).0 == 401, "HTTP: old token stops working after regenerating")
        server.setEnabled(false)
        expect(server.state == .stopped, "server stops when disabled")
    }
}
