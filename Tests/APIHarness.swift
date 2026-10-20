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

        // Creating
        let personal = store.createProject(Project(id: "", name: "Health", type: .personal))
        let newTask: [String: Any] = [
            "fields": ["title": "  Sweep lr 1e-4..1e-3 ", "project_id": project.id, "status": "Running", "setup": "5 seeds",
                       "chat_ids": ["codex-2"], "metrics": [["name": "lr", "value": 0.0003]]],
            "source_chat_id": "codex-2", "idempotency_key": "codex-2/create-1",
        ]
        let (createStatus, created) = call("POST", "/v1/tasks", body: newTask)
        let ct = created["task"] as? [String: Any] ?? [:]
        let newID = ct["id"] as? String ?? ""
        expect(createStatus == 201 && created["duplicate"] as? Bool == false && ct["title"] as? String == "Sweep lr 1e-4..1e-3"
               && ct["kind"] as? String == "experiment" && ct["status"] as? String == "Running" && ct["revision"] as? Int == 1,
               "create_task → 201 with saved task at revision 1")
        expect(ct["run_started_at"] is String && ct["chat_ids"] as? [String] == ["codex-2"] && ct["setup"] as? String == "5 seeds",
               "created running experiment gets a run start, chat link, and fields")
        let createdLog = (ct["progress_log"] as? [[String: Any]])?.first
        expect(createdLog?["kind"] as? String == "created" && createdLog?["author"] as? String == "api"
               && createdLog?["source_chat_id"] as? String == "codex-2", "creation logged with author api and source chat")
        expect(store.item(newID)?.projectID == project.id, "created task is in the store the UI reads")

        var renamed = store.item(newID)!
        renamed.title = "Renamed in the app"
        store.updateItem(renamed)
        let (replayCreateStatus, replayCreate) = call("POST", "/v1/tasks", body: newTask)
        expect(replayCreateStatus == 200 && replayCreate["duplicate"] as? Bool == true
               && (replayCreate["task"] as? [String: Any])?["id"] as? String == newID, "replayed create returns the same task, even after edits")
        expect(store.items.filter { $0.chatIDs.contains("codex-2") }.count == 1, "no duplicate task created")
        let otherTitle = call("POST", "/v1/tasks", body: ["fields": ["title": "Other"], "source_chat_id": "codex-2", "idempotency_key": "codex-2/create-1"])
        expect(otherTitle.0 == 409 && code(otherTitle.1) == "idempotency_conflict", "create key reused for another task → idempotency_conflict")
        expect(code(call("POST", "/v1/tasks", body: ["fields": ["title": "x"], "idempotency_key": "k1"]).1) == "idempotency_conflict",
               "create key that belongs to a progress entry → idempotency_conflict")

        let minimal = call("POST", "/v1/tasks", body: ["fields": ["title": "Quick check"]])
        let mt = minimal.1["task"] as? [String: Any]
        expect(minimal.0 == 201 && mt?["kind"] as? String == "experiment" && mt?["status"] as? String == "Planned"
               && mt?["project_id"] is NSNull, "defaults: experiment, Planned, no project")
        let inPersonal = call("POST", "/v1/tasks", body: ["fields": ["title": "Book physio", "project_id": personal.id]])
        expect((inPersonal.1["task"] as? [String: Any])?["kind"] as? String == "personal", "kind follows a personal project's type")
        let explicitKind = call("POST", "/v1/tasks", body: ["fields": ["title": "Fix loader", "kind": "coding", "project_id": project.id]])
        expect((explicitKind.1["task"] as? [String: Any])?["kind"] as? String == "coding", "explicit kind wins")

        let countBefore = store.items.count
        expect(errorField(call("POST", "/v1/tasks", body: ["fields": ["setup": "x"]]).1) == "title", "create without title rejected")
        expect(errorField(call("POST", "/v1/tasks", body: ["fields": ["title": "x", "kind": "experiments"]]).1) == "kind", "unknown kind rejected")
        expect(errorField(call("POST", "/v1/tasks", body: ["fields": ["title": "x", "status": "failed"]]).1) == "status", "chat status rejected on create")
        expect(errorField(call("POST", "/v1/tasks", body: ["fields": ["title": "x", "project_id": "nope"]]).1) == "project_id", "unknown project rejected on create")
        expect(errorField(call("POST", "/v1/tasks", body: ["title": "x"]).1) == "title", "fields outside `fields` rejected on create")
        expect(code(call("POST", "/v1/tasks", body: ["fields": ["title": "x"]], token: nil).1) == "unauthorized", "create needs the token")
        expect(store.items.count == countBefore, "rejected creates add nothing")

        // Creating projects
        let newProject: [String: Any] = [
            "fields": ["name": "  Long-Context Eval ", "summary": "NeurIPS 2027", "deadline": "2027-05-15", "symbol": "brain"],
            "source_chat_id": "codex-3", "idempotency_key": "codex-3/project-1",
        ]
        let (projStatus, projCreated) = call("POST", "/v1/projects", body: newProject)
        let np = projCreated["project"] as? [String: Any] ?? [:]
        let npID = np["id"] as? String ?? ""
        expect(projStatus == 201 && projCreated["duplicate"] as? Bool == false && np["name"] as? String == "Long-Context Eval"
               && np["type"] as? String == "research" && np["status"] as? String == "active" && np["deadline"] as? String == "2027-05-15"
               && np["symbol"] as? String == "brain" && np["color"] as? String == ProjectType.research.defaultColor,
               "create_project → 201 with saved project and defaults")
        expect(store.project(npID)?.summary == "NeurIPS 2027", "created project is in the store the UI reads")
        let projectLog = store.logs(since: .distantPast, projectID: npID).first
        expect(projectLog?.kind == "created" && projectLog?.author == .api && projectLog?.sourceChatID == "codex-3",
               "project creation logged with author api and source chat")
        let listed = (call("GET", "/v1/projects").1["projects"] as? [[String: Any]])?.first { $0["id"] as? String == npID }
        expect(listed?["summary"] as? String == "NeurIPS 2027" && listed?["deadline"] as? String == "2027-05-15", "list_projects shows the new project in full")

        var renamedProject = store.project(npID)!
        renamedProject.name = "Renamed project"
        store.updateProject(renamedProject)
        let (replayProjStatus, replayProj) = call("POST", "/v1/projects", body: newProject)
        expect(replayProjStatus == 200 && replayProj["duplicate"] as? Bool == true
               && (replayProj["project"] as? [String: Any])?["id"] as? String == npID, "replayed create_project returns the same project")
        expect(code(call("POST", "/v1/projects", body: ["fields": ["name": "Else"], "source_chat_id": "codex-3", "idempotency_key": "codex-3/project-1"]).1)
               == "idempotency_conflict", "project key reused for another project → idempotency_conflict")
        expect(code(call("POST", "/v1/projects", body: ["fields": ["name": "x"], "idempotency_key": "codex-2/create-1"]).1) == "idempotency_conflict",
               "project key that belongs to a task → idempotency_conflict")

        let exists = call("POST", "/v1/projects", body: ["fields": ["name": "sparse attention"]])
        expect(exists.0 == 409 && code(exists.1) == "project_exists"
               && ((exists.1["error"] as? [String: Any])?["project"] as? [String: Any])?["id"] as? String == project.id,
               "same name (case-insensitive) → 409 project_exists with the existing project")
        var archived = store.project(personal.id)!
        archived.status = .archived
        store.updateProject(archived)
        expect(call("POST", "/v1/projects", body: ["fields": ["name": "Health", "type": "personal"]]).0 == 201,
               "an archived project's name can be reused")
        let misc = call("POST", "/v1/projects", body: ["fields": ["name": "Errands", "type": "misc", "status": "paused"]]).1["project"] as? [String: Any]
        expect(misc?["type"] as? String == "misc" && misc?["status"] as? String == "paused" && misc?["symbol"] as? String == ProjectType.misc.defaultSymbol,
               "type and status set; look follows the type")

        let projectCount = store.projects.count
        expect(errorField(call("POST", "/v1/projects", body: ["fields": ["summary": "x"]]).1) == "name", "create_project without name rejected")
        expect(errorField(call("POST", "/v1/projects", body: ["fields": ["name": "x", "type": "work"]]).1) == "type", "unknown project type rejected")
        expect(errorField(call("POST", "/v1/projects", body: ["fields": ["name": "x", "deadline": "15/05/2027"]]).1) == "deadline", "bad deadline rejected")
        expect(errorField(call("POST", "/v1/projects", body: ["fields": ["name": "x", "color": "magenta"]]).1) == "color", "unknown color rejected")
        expect(errorField(call("POST", "/v1/projects", body: ["fields": ["name": "x", "owner": "me"]]).1) == "owner", "unknown project field rejected")
        expect(code(call("POST", "/v1/projects", body: ["fields": ["name": "x"]], token: nil).1) == "unauthorized", "create_project needs the token")
        expect(store.projects.count == projectCount, "rejected project creates add nothing")
        expect(Store(url: url).project(npID)?.deadline != nil, "created project persists")

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
        let (s3, made) = await send("POST", "/tasks", token: token, body: ["fields": ["title": "Created over HTTP"], "idempotency_key": "http-1"])
        let madeID = (made["task"] as? [String: Any])?["id"] as? String
        expect(s3 == 201 && store.item(madeID)?.title == "Created over HTTP", "HTTP: create_task")
        let (s4, madeProject) = await send("POST", "/projects", token: token, body: ["fields": ["name": "HTTP Project"], "idempotency_key": "http-p1"])
        expect(s4 == 201 && store.project((madeProject["project"] as? [String: Any])?["id"] as? String)?.name == "HTTP Project", "HTTP: create_project")

        server.regenerateToken()
        expect(await send("GET", "/tasks", token: token).0 == 401, "HTTP: old token stops working after regenerating")
        server.setEnabled(false)
        expect(server.state == .stopped, "server stops when disabled")
    }
}
