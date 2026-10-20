// Acceptance checks for internal/external parity: the same operations run through the assistant's tools and through
// POST /v1/tools on two scratch stores must give equivalent results (ids, timestamps, and authorship aside).
import Foundation

@MainActor
enum ParityHarness {
    /// One operation call, run identically through both interfaces. Strings starting with `$` in `args`, and a
    /// string `revision`, are replaced by values saved from earlier results of the same interface.
    struct Step {
        var name: String
        var args: [String: Any] = [:]
        var revision: Any?
        var key: String?
        var save: [String: [Any]] = [:]
        var error: String?
        var check: ((_ body: [String: Any]) -> Bool)?
        var what: String
    }

    static func run(expect: (Bool, String) -> Void) async {
        print("\n— parity: assistant tools vs. /v1/tools —")
        let urls = (0..<2).map { _ in URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-parity-\(UUID().uuidString).sqlite") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let agentStore = Store(url: urls[0]), apiStore = Store(url: urls[1])
        let tools = AgentTools(store: agentStore)
        let api = TaskAPI(store: apiStore, token: "t")

        // The contract is the same: one registry, same names and input schemas.
        let discovery = Self.json(api.handle(APIRequest(method: "GET", path: "/v1/tools", headers: ["authorization": "Bearer t"])).body)
        let operations = discovery["operations"] as? [[String: Any]] ?? []
        let required = ["list_items", "get_item", "create_item", "update_item", "update_checklist", "add_log",
                        "list_projects", "create_project", "update_project", "review_summary"]
        expect(operations.compactMap { $0["name"] as? String } == required, "GET /v1/tools lists the ten shared operations")
        expect(AgentTools.definitions.compactMap { $0["name"] as? String } == required, "assistant tools are the same operations")
        let sameInputs = zip(AgentTools.definitions, operations).allSatisfy {
            Wire.string($0["input_schema"] ?? [:]) == Wire.string($1["input_schema"] ?? [:])
        }
        expect(sameInputs, "assistant and API share identical input schemas")
        expect(operations.allSatisfy { $0["output_schema"] is [String: Any] && $0["mutates"] is Bool }, "every operation publishes output schema and mutates flag")
        let mutating = Set(operations.filter { $0["mutates"] as? Bool == true }.compactMap { $0["name"] as? String })
        expect(mutating == ["create_item", "update_item", "update_checklist", "add_log", "create_project", "update_project"], "mutating operations flagged")

        var vars: [[String: Any]] = [[:], [:]]
        let normalizers = [Normalizer(), Normalizer()]
        var mismatches = 0, schemaFailures = 0

        func substitute(_ v: Any, _ run: Int) -> Any {
            if let s = v as? String, s.hasPrefix("$") { return vars[run][String(s.dropFirst())] ?? s }
            if let a = v as? [Any] { return a.map { substitute($0, run) } }
            if let d = v as? [String: Any] { return d.mapValues { substitute($0, run) } }
            return v
        }

        func call(_ step: Step, _ run: Int) -> [String: Any] {
            let args = substitute(step.args, run) as? [String: Any] ?? [:]
            let revision = step.revision.map { substitute($0, run) } as? Int
            if run == 0 {
                return Self.json(Data(tools.run(name: step.name, input: args, expectedRevision: revision, idempotencyKey: step.key).result.utf8))
            }
            var body: [String: Any] = ["arguments": args]
            if let revision { body["expected_revision"] = revision }
            if let key = step.key { body["idempotency_key"] = key }
            let r = api.handle(APIRequest(method: "POST", path: "/v1/tools/\(step.name)", headers: ["authorization": "Bearer t"], body: Wire.data(body)))
            var json = Self.json(r.body)
            let code = (json["error"] as? [String: Any])?["code"] as? String
            if r.status != (code.map { OperationError(code: $0, message: "").httpStatus } ?? 200) { json["http_status_mismatch"] = r.status }
            return json
        }

        func perform(_ step: Step) {
            let bodies = [call(step, 0), call(step, 1)]
            for run in 0..<2 {
                for (name, path) in step.save { vars[run][name] = Self.value(bodies[run], path) }
            }
            let normalized = (0..<2).map { normalizers[$0].normalize(bodies[$0]) }
            let same = normalized[0] == normalized[1]
            if !same {
                mismatches += 1
                print("    agent: \(normalized[0].prefix(900))\n    api:   \(normalized[1].prefix(900))")
            }
            let code = (bodies[0]["error"] as? [String: Any])?["code"] as? String
            var ok = same && code == step.error
            if code == nil, let op = OperationRegistry.named(step.name) {
                let problems = SchemaCheck.validate(bodies[0]["result"] ?? NSNull(), op.output, path: "result")
                    + SchemaCheck.validate(bodies[0], OperationRegistry.envelopeSchema, path: "envelope")
                if !problems.isEmpty { schemaFailures += 1; ok = false; print("    schema: \(problems.prefix(3))") }
            }
            if let check = step.check { ok = ok && check(bodies[0]) }
            if code != step.error { print("    expected error \(step.error ?? "none"), got \(code ?? "none"): \(bodies[0]["error"] ?? "")") }
            expect(ok, "both: \(step.what)")
        }

        func result(_ b: [String: Any]) -> [String: Any] { b["result"] as? [String: Any] ?? [:] }
        func item(_ b: [String: Any]) -> [String: Any] { result(b)["item"] as? [String: Any] ?? [:] }
        func errorField(_ b: [String: Any]) -> String? { (b["error"] as? [String: Any])?["field"] as? String }

        let steps: [Step] = [
            // 6. Projects
            Step(name: "create_project", args: ["name": "Parity Paper", "summary": "ICML 2027", "deadline": "2027-01-30"],
                 save: ["p1": ["result", "project", "id"], "p1rev": ["result", "project", "revision"]],
                 check: { (result($0)["project"] as? [String: Any])?["type"] as? String == "research" }, what: "create research project"),
            Step(name: "create_project", args: ["name": "Health", "type": "personal"], save: ["p2": ["result", "project", "id"]],
                 what: "create personal project"),
            Step(name: "create_project", args: ["name": "parity paper"], error: "project_exists", what: "duplicate project name rejected"),

            // 1. Creation with an initial checklist and quantitative progress
            Step(name: "create_item", args: [
                "title": "Ablation: sparsity", "kind": "experiment", "project_id": "$p1", "priority": "high", "tags": ["abl"],
                "due_date": "2027-01-10", "today": true, "hypothesis": "ppl within 2%", "setup": "bs=64", "compute": "4xA100",
                "metrics": [["name": "ppl", "value": 18.9]], "chat_ids": ["chat-a"], "checklist": ["prepare data", "run baseline", "run sparse"],
                "progress_target": 10, "progress_unit": "runs", "progress": 4,
            ], save: ["exp": ["result", "item", "id"], "baseline": ["result", "item", "checklist", 1, "id"]],
                 check: {
                     let i = item($0)
                     return i["status"] as? String == "in_progress" && i["progress_current"] as? Int == 4 && i["progress_target"] as? Int == 10
                         && i["tracks_progress"] as? Bool == true && (i["checklist"] as? [[String: Any]])?.map { $0["position"] as? Int } == [0, 1, 2]
                         && i["run_started_at"] is String && (i["metrics"] as? [[String: String]])?.first?["value"] == "18.9"
                 }, what: "create item with checklist and progress (count starts it)"),
            Step(name: "create_item", args: ["title": "Sparse kernel", "kind": "coding", "project_id": "$p1", "repo": "github.com/x/y",
                                             "branch": "feat/sparse", "link": "https://github.com/x/y/pull/1", "status": "in_progress"],
                 save: ["code": ["result", "item", "id"]], what: "create coding item with coding fields"),
            Step(name: "create_item", args: ["title": "Read 5 papers", "kind": "reading", "progress_target": 5, "progress": 5, "status": "todo"],
                 save: ["read": ["result", "item", "id"]],
                 check: { item($0)["status"] as? String == "todo" }, what: "explicit status on create wins over the count"),

            // 2. Checklist
            Step(name: "update_checklist", args: ["item_id": "$exp", "add": ["analyze", "write up"], "check": ["Prepare Data", "$baseline"]],
                 check: {
                     let r = result($0), list = r["checklist"] as? [[String: Any]] ?? []
                     return (r["added"] as? [[String: Any]])?.count == 2 && list.map { $0["done"] as? Bool } == [true, true, false, false, false]
                         && list.map { $0["position"] as? Int } == [0, 1, 2, 3, 4] && r["changed"] as? Bool == true
                 }, what: "checklist add + check by title and by id"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "uncheck": ["prepare data"], "remove": ["run sparse"]],
                 check: { (result($0)["checklist"] as? [[String: Any]])?.map { $0["title"] as? String } == ["prepare data", "run baseline", "analyze", "write up"] },
                 what: "checklist uncheck + remove keeps order and other steps"),
            Step(name: "get_item", args: ["id": "$exp"],
                 check: { item($0)["progress_current"] as? Int == 4 }, what: "checklist changes don't touch the count"),

            // 3–4. Progress
            Step(name: "update_item", args: ["id": "$exp", "progress": 6], check: { item($0)["progress_current"] as? Int == 6 }, what: "absolute progress"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 2], check: { item($0)["progress_current"] as? Int == 8 }, what: "positive increment"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": -3], check: { item($0)["progress_current"] as? Int == 5 }, what: "negative increment"),
            Step(name: "update_item", args: ["id": "$exp", "progress": 2, "progress_add": 1],
                 check: { item($0)["progress_current"] as? Int == 3 }, what: "progress then progress_add in one request"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 7],
                 check: { item($0)["status"] as? String == "done" && item($0)["progress_label"] as? String == "10/10 runs" }, what: "reaching the target completes"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": -1],
                 check: { item($0)["status"] as? String == "in_progress" }, what: "falling below the target reopens"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 1, "status": "blocked"],
                 check: { item($0)["status"] as? String == "blocked" && item($0)["progress_current"] as? Int == 10 }, what: "explicit status wins over the count"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": -50],
                 check: { item($0)["progress_current"] as? Int == 0 }, what: "count stops at zero"),
            Step(name: "update_item", args: ["id": "$code", "progress_target": 3, "progress_unit": "PRs", "progress": 1],
                 check: { item($0)["progress_label"] as? String == "1/3 PRs" }, what: "target and count in one request"),
            Step(name: "update_item", args: ["id": "$code", "progress_target": 0],
                 check: { item($0)["tracks_progress"] as? Bool == false }, what: "target 0 stops tracking"),
            Step(name: "update_item", args: ["id": "$code", "progress_add": 1], error: "invalid_field", what: "progress needs a target"),
            Step(name: "update_item", args: ["id": "$exp", "progress": true], error: "invalid_field", what: "boolean count rejected"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 1.5], error: "invalid_field", what: "fractional count rejected"),
            Step(name: "update_item", args: ["id": "$exp", "progress_target": -2], error: "invalid_field", what: "negative target rejected"),

            // 5. Notes, logs, coding and experiment fields, linked chats
            Step(name: "update_item", args: [
                "id": "$exp", "status": "Analyzing", "append_notes": "seed 2 diverged", "log": "Runs finished", "results": "+1.4% ppl",
                "conclusion": "keep 0.9", "outcome": "supported", "metrics": [["name": "ppl", "value": "19.1"], ["name": "speedup", "value": 1.8]],
                "chat_ids": ["chat-a", "chat-b", "chat-a"], "run_ended_at": "now",
            ], check: {
                let i = item($0)
                return i["status"] as? String == "waiting" && i["notes"] as? String == "seed 2 diverged" && i["chat_ids"] as? [String] == ["chat-a", "chat-b"]
                    && (i["progress_log"] as? [[String: Any]])?.first?["text"] as? String == "Runs finished"
                    && Set(result($0)["changed"] as? [String] ?? []).isSuperset(of: ["status", "notes", "results", "conclusion", "outcome", "metrics", "chat_ids"])
            }, what: "experiment fields, notes, log, chat links (status alias accepted)"),
            Step(name: "update_item", args: ["id": "$exp", "append_notes": "seed 3 fine"],
                 check: { item($0)["notes"] as? String == "seed 2 diverged\n\nseed 3 fine" }, what: "append_notes appends"),
            Step(name: "update_item", args: ["id": "$code", "branch": "feat/sparse-v2", "kind": "experiment", "project_id": "", "due_date": "2027-02-01"],
                 check: { item($0)["kind"] as? String == "experiment" && item($0)["project_id"] is NSNull && item($0)["repo"] as? String == "github.com/x/y" },
                 what: "kind change, clear project, other fields preserved"),
            Step(name: "update_item", args: ["id": "$code", "due_date": "", "run_started_at": ""],
                 check: { item($0)["due_date"] is NSNull && item($0)["run_started_at"] is NSNull }, what: "empty strings clear dates"),
            Step(name: "add_log", args: ["item_id": "$exp", "text": "Shared results with the group"],
                 check: { (result($0)["log_entry"] as? [String: Any])?["kind"] as? String == "note" }, what: "add_log appends a note"),
            Step(name: "get_item", args: ["id": "$exp", "log_limit": 50],
                 check: { item($0)["progress_current"] as? Int == 0 && (item($0)["progress_log"] as? [[String: Any]])?.count ?? 0 > 5 },
                 what: "log appends leave the count alone"),
            Step(name: "update_project", args: ["id": "$p1", "name": "Parity Paper v2", "status": "paused", "color": "green", "deadline": ""],
                 save: ["p1rev": ["result", "project", "revision"]],
                 check: { Set(result($0)["changed"] as? [String] ?? []) == ["name", "status", "color", "deadline"] }, what: "update project"),
            Step(name: "update_project", args: ["id": "$p1", "name": "Health"], error: "project_exists", what: "rename onto an existing name rejected"),

            // 6. Filtering and review
            Step(name: "list_items", args: ["status": "any"], check: { result($0)["total"] as? Int == 3 }, what: "list all"),
            Step(name: "list_items", args: ["kind": "experiment", "status": "any", "sort": "updated"], check: { result($0)["total"] as? Int == 2 }, what: "filter by kind"),
            Step(name: "list_items", args: ["project_id": "$p1", "status": "any"], check: { result($0)["total"] as? Int == 1 }, what: "filter by project"),
            Step(name: "list_items", args: ["area": "research", "query": "SPARSE", "status": "open"], what: "filter by area and text"),
            Step(name: "list_items", args: ["title": "ablation", "chat_id": "chat-b", "status": "Analyzing"],
                 check: { result($0)["total"] as? Int == 1 }, what: "filter by title, chat, status alias"),
            Step(name: "list_items", args: ["today": true, "limit": 1], what: "Today filter and limit"),
            Step(name: "list_items", args: ["project_id": "nope"], error: "project_not_found", what: "unknown project filter"),
            Step(name: "list_projects", args: [:], check: { (result($0)["projects"] as? [[String: Any]])?.count == 2 }, what: "list projects"),
            Step(name: "list_projects", args: ["type": "personal", "include_archived": true], what: "list projects by type"),
            Step(name: "review_summary", args: ["days": 7], check: { result($0)["created_count"] as? Int == 3 }, what: "review summary"),

            // Structured errors, all-or-nothing
            Step(name: "update_checklist", args: ["item_id": "$exp", "add": ["dup", "dup"]], what: "add duplicate titles"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "check": ["dup"]], error: "ambiguous_match", what: "ambiguous title rejected"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "check": ["analyze"], "uncheck": ["Analyze"]],
                 error: "contradictory_operations", what: "contradictory actions rejected"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "add": ["should not appear"], "remove": ["no such step"]],
                 error: "checklist_entry_not_found", what: "invalid batch rejected"),
            Step(name: "update_item", args: ["id": "$exp", "title": "Should not stick", "priority": "urgent"], error: "invalid_field", what: "invalid update rejected"),
            Step(name: "get_item", args: ["id": "$exp"],
                 check: {
                     let i = item($0)
                     return i["title"] as? String == "Ablation: sparsity"
                         && !((i["checklist"] as? [[String: Any]]) ?? []).contains { $0["title"] as? String == "should not appear" }
                 }, what: "rejected batches left nothing behind"),
            Step(name: "update_item", args: ["id": "$exp", "status": "completed"], error: "invalid_field", what: "chat execution status rejected"),
            Step(name: "update_item", args: ["id": "$exp", "author": "user"], error: "invalid_field", what: "author can't be set by arguments"),
            Step(name: "get_item", args: ["id": "missing"], error: "item_not_found", what: "missing item"),
            Step(name: "frobnicate", args: [:], error: "unknown_operation", what: "unknown operation"),

            // 7. Revisions and idempotent retries
            Step(name: "get_item", args: ["id": "$exp"], save: ["rev": ["result", "item", "revision"]], what: "read revision"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 2], revision: "$rev", key: "inc-1",
                 check: { item($0)["progress_current"] as? Int == 2 && $0["replayed"] as? Bool == false }, what: "increment with revision and key"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 2], revision: "$rev", key: "inc-1",
                 check: { $0["replayed"] as? Bool == true }, what: "replay recognized before its stale revision"),
            Step(name: "get_item", args: ["id": "$exp"], check: { item($0)["progress_current"] as? Int == 2 }, what: "replayed increment applied once"),
            Step(name: "update_item", args: ["id": "$exp", "notes": "stale write"], revision: "$rev", error: "revision_conflict", what: "stale revision rejected"),
            Step(name: "update_item", args: ["id": "$exp", "progress_add": 3], key: "inc-1", error: "idempotency_conflict", what: "key reused for other content"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "add": ["retry-safe step"]], key: "add-1", what: "checklist add with key"),
            Step(name: "update_checklist", args: ["item_id": "$exp", "add": ["retry-safe step"]], key: "add-1",
                 check: { $0["replayed"] as? Bool == true }, what: "checklist add replayed"),
            Step(name: "add_log", args: ["item_id": "$exp", "text": "once"], key: "log-1", what: "log with key"),
            Step(name: "add_log", args: ["item_id": "$exp", "text": "once"], key: "log-1", what: "log replayed"),
            Step(name: "update_item", args: ["id": "$exp", "append_notes": "once"], key: "note-1", what: "append with key"),
            Step(name: "update_item", args: ["id": "$exp", "append_notes": "once"], key: "note-1", what: "append replayed"),
            Step(name: "create_item", args: ["title": "Created once", "kind": "task"], key: "create-1", save: ["once": ["result", "item", "id"]], what: "create with key"),
            Step(name: "create_item", args: ["title": "Created once", "kind": "task"], key: "create-1", what: "create replayed"),
            Step(name: "get_item", args: ["id": "$exp", "log_limit": 100],
                 check: {
                     let i = item($0), log = i["progress_log"] as? [[String: Any]] ?? []
                     return ((i["checklist"] as? [[String: Any]]) ?? []).filter { $0["title"] as? String == "retry-safe step" }.count == 1
                         && log.filter { $0["text"] as? String == "once" }.count == 1 && (i["notes"] as? String)?.hasSuffix("once") == true
                         && (i["notes"] as? String)?.components(separatedBy: "once").count == 2
                 }, what: "replayed mutations had no second effect"),
            Step(name: "list_items", args: ["title": "Created once", "status": "any"], check: { result($0)["total"] as? Int == 1 }, what: "replayed create made one item"),
            Step(name: "update_project", args: ["id": "$p1", "summary": "late"], revision: 1, error: "revision_conflict", what: "stale project revision rejected"),
            Step(name: "update_project", args: ["id": "$p1", "summary": "on time"], revision: "$p1rev", what: "project update with current revision"),
            Step(name: "create_item", args: ["title": "x", "kind": "task"], revision: 3, error: "invalid_field", what: "expected_revision not accepted for creates"),
        ]
        for step in steps { perform(step) }
        expect(mismatches == 0, "assistant and API results equivalent at every step (\(mismatches) mismatch(es))")
        expect(schemaFailures == 0, "every result matches its published output schema")

        // Authorship: the same audit trail, attributed to each caller.
        let agentAuthors = Set(agentStore.logs(since: .distantPast).map(\.author)), apiAuthors = Set(apiStore.logs(since: .distantPast).map(\.author))
        expect(agentAuthors == [.agent] && apiAuthors == [.api], "audit entries attributed to agent and api")

        // 8. Immediate visibility in the store the UI reads, and persistence after a restart.
        let expAPI = vars[1]["exp"] as? String ?? ""
        expect(apiStore.item(expAPI)?.progressCurrent == 2 && apiStore.item(expAPI)?.chatIDs == ["chat-a", "chat-b"], "API writes visible to the UI at once")
        for run in 0..<2 {
            let url = urls[run], id = vars[run]["exp"] as? String ?? ""
            let before = Normalizer().normalize(OperationService(store: run == 0 ? agentStore : apiStore)
                .invoke("get_item", ["id": id, "log_limit": 100], context: OperationContext(author: .api)).body)
            let after = Normalizer().normalize(OperationService(store: Store(url: url))
                .invoke("get_item", ["id": id, "log_limit": 100], context: OperationContext(author: .api)).body)
            expect(before == after, "\(run == 0 ? "assistant" : "API") changes survive a restart")
        }

        await atomicity(expect: expect)
        await legacyBridges(expect: expect)
    }

    /// A failure inside a group leaves both the database and the in-memory copy untouched.
    private static func atomicity(expect: (Bool, String) -> Void) async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-parity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = Store(url: url)
        let item = store.createItem(Item(id: "", title: "Atomic", kind: .task))
        struct Boom: Error {}
        do {
            try store.atomically {
                var copy = store.item(item.id)!
                copy.title = "Half-written"
                try store.saveItem(copy, author: .api)
                try store.appendNote("note", itemID: item.id, author: .api)
                throw Boom()
            }
        } catch {}
        expect(store.item(item.id)?.title == "Atomic" && store.item(item.id)?.revision == 1, "failed group rolls back the in-memory copy")
        expect(Store(url: url).item(item.id)?.title == "Atomic" && store.logs(forItem: item.id).count == 1, "failed group rolls back the database and its audit entries")
    }

    /// The v1 endpoints are adapters over the same operations, so idempotency keys work across both.
    private static func legacyBridges(expect: (Bool, String) -> Void) async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dr-parity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = Store(url: url)
        let api = TaskAPI(store: store, token: "t")
        func send(_ method: String, _ path: String, _ body: [String: Any]) -> (Int, [String: Any]) {
            let r = api.handle(APIRequest(method: method, path: path, headers: ["authorization": "Bearer t"], body: Wire.data(body)))
            return (r.status, json(r.body))
        }
        let item = store.createItem(Item(id: "", title: "Bridge", kind: .experiment))
        _ = send("POST", "/v1/tasks/\(item.id)/progress", ["text": "Epoch 1", "source_chat_id": "c1", "idempotency_key": "bridge-1"])
        let (status, replay) = send("POST", "/v1/tools/add_log", ["arguments": ["item_id": item.id, "text": "Epoch 1"],
                                                                   "source_chat_id": "c1", "idempotency_key": "bridge-1"])
        expect(status == 200 && replay["replayed"] as? Bool == true, "v1 progress entry and add_log share idempotency")
        let (s2, patched) = send("PATCH", "/v1/tasks/\(item.id)", ["fields": ["progress_target": 4, "progress_add": 1, "tags": ["x"]]])
        let task = patched["task"] as? [String: Any]
        expect(s2 == 200 && task?["progress_current"] as? Int == 1 && task?["status"] as? String == "Running"
               && Set(patched["changed"] as? [String] ?? []) == ["progress_target", "progress_add", "tags"],
               "v1 PATCH accepts every update_item field and reports counts")
        let (s3, logged) = send("POST", "/v1/tasks/\(item.id)/progress", ["text": "no count change", "source_chat_id": "c1", "idempotency_key": "bridge-2"])
        expect(s3 == 201 && logged["revision"] as? Int == (store.item(item.id)?.revision ?? -1) && store.item(item.id)?.progressCurrent == 1,
               "v1 progress endpoint logs text without changing the count")
    }

    // MARK: Helpers

    static func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func value(_ object: Any, _ path: [Any]) -> Any? {
        var current: Any? = object
        for component in path {
            if let key = component as? String { current = (current as? [String: Any])?[key] }
            if let index = component as? Int { current = (current as? [Any]).flatMap { index < $0.count ? $0[index] : nil } }
        }
        return current
    }

    /// Replaces generated ids with placeholders in order of first appearance, and drops what differs by design:
    /// timestamps and the author. Kept across steps, so ids map consistently over a whole run.
    final class Normalizer {
        private var ids: [String: String] = [:]
        private static let dropped: Set<String> = ["created_at", "updated_at", "completed_at", "run_started_at", "run_ended_at", "author"]

        func normalize(_ value: Any) -> String {
            collect(value)
            return Wire.string(clean(value))
        }

        private func collect(_ value: Any) {
            if let d = value as? [String: Any] {
                for key in d.keys.sorted() {
                    if ["id", "item_id", "project_id", "task_id"].contains(key), let s = d[key] as? String, ids[s] == nil {
                        ids[s] = "<id\(ids.count)>"
                    }
                    collect(d[key]!)
                }
            } else if let a = value as? [Any] {
                a.forEach(collect)
            }
        }

        private func clean(_ value: Any) -> Any {
            if let d = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: d.filter { !Self.dropped.contains($0.key) }.map { ($0.key, clean($0.value)) })
            }
            if let a = value as? [Any] { return a.map(clean) }
            if var s = value as? String {
                if let exact = ids[s] { return exact }
                for (id, placeholder) in ids where s.contains(id) { s = s.replacingOccurrences(of: id, with: placeholder) }
                return s
            }
            return value
        }
    }
}

/// A small JSON Schema checker covering what the published schemas use: type, enum, properties, required,
/// additionalProperties, items, and anyOf.
enum SchemaCheck {
    static func validate(_ value: Any, _ schema: [String: Any], path: String) -> [String] {
        if let options = schema["anyOf"] as? [[String: Any]] {
            return options.contains { validate(value, $0, path: path).isEmpty } ? [] : ["\(path): matches no anyOf option"]
        }
        var problems: [String] = []
        if let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map({ [$0] }), !types.contains(where: { matches(value, $0) }) {
            return ["\(path): expected \(types.joined(separator: "|")), got \(Swift.type(of: value))"]
        }
        if let allowed = schema["enum"] as? [String], let s = value as? String, !allowed.contains(s) {
            problems.append("\(path): \(s) not in enum")
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { problems.append("\(path).\(key): missing") }
            for (key, v) in object {
                if let sub = properties[key] as? [String: Any] {
                    problems += validate(v, sub, path: "\(path).\(key)")
                } else if let extra = schema["additionalProperties"] as? [String: Any] {
                    problems += validate(v, extra, path: "\(path).\(key)")
                } else if schema["additionalProperties"] as? Bool == false {
                    problems.append("\(path).\(key): not in schema")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (i, v) in array.enumerated() { problems += validate(v, items, path: "\(path)[\(i)]") }
        }
        return problems
    }

    private static func matches(_ value: Any, _ type: String) -> Bool {
        let isBool = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch type {
        case "null": return value is NSNull
        case "boolean": return isBool
        case "integer": return !isBool && (value as? NSNumber).map { $0.doubleValue == $0.doubleValue.rounded() } ?? false
        case "number": return !isBool && value is NSNumber
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return true
        }
    }
}
