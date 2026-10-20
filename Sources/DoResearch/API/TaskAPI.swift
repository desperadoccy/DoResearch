import Foundation

struct APIRequest {
    var method: String
    /// Path without the query string, still percent-encoded.
    var path: String
    var query: [String: String] = [:]
    /// Lowercased header names.
    var headers: [String: String] = [:]
    var body = Data()
}

struct APIResponse {
    var status: Int
    var body: Data

    static func json(_ status: Int, _ object: Any) -> APIResponse {
        APIResponse(status: status, body: Wire.data(object))
    }
}

extension OperationError {
    static func unauthorized() -> OperationError {
        OperationError(code: "unauthorized", message: "Missing or invalid bearer token. Send `Authorization: Bearer <token>`.")
    }

    var response: APIResponse { .json(httpStatus, json) }
}

/// The local HTTP API (docs/API.md). `/v1/tools` exposes the shared operations of `OperationRegistry`, exactly as the
/// built-in assistant calls them. The task and project endpoints from API v1 are kept as adapters that translate
/// their requests into the same operations and answer in their original shapes. Runs on the main actor, so a
/// revision check and its write can't interleave with UI edits.
@MainActor
struct TaskAPI {
    let store: Store
    let token: String

    static let version = 1
    static let maxLogLimit = 500

    private var service: OperationService { OperationService(store: store) }

    func handle(_ request: APIRequest) -> APIResponse {
        do {
            return try route(request)
        } catch let error as OperationError {
            return error.response
        } catch {
            return OperationError.storage(error).response
        }
    }

    private func route(_ r: APIRequest) throws -> APIResponse {
        let parts = r.path.split(separator: "/", omittingEmptySubsequences: true).map { $0.removingPercentEncoding ?? String($0) }
        guard parts.first == "v1" else { throw notFound(r.path) }
        let rest = Array(parts.dropFirst())

        if rest == ["health"] {
            try allow(r, "GET")
            return .json(200, ["ok": true, "api_version": Self.version])
        }
        try authenticate(r)
        switch rest.count {
        case 1 where rest[0] == "tools":
            try allow(r, "GET")
            return .json(200, discovery())
        case 2 where rest[0] == "tools":
            try allow(r, "POST")
            return try invoke(rest[1], r)
        case 1 where rest[0] == "statuses":
            try allow(r, "GET")
            return statuses()
        case 1 where rest[0] == "projects":
            try allow(r, "GET", "POST")
            return r.method == "GET" ? try listProjects(r) : try createProject(r)
        case 1 where rest[0] == "tasks":
            try allow(r, "GET", "POST")
            return r.method == "GET" ? try listTasks(r) : try createTask(r)
        case 2 where rest[0] == "tasks":
            try allow(r, "GET", "PATCH")
            return r.method == "GET" ? try getTask(rest[1], r) : try updateTask(rest[1], r)
        case 3 where rest[0] == "tasks" && rest[2] == "progress":
            try allow(r, "POST")
            return try appendProgress(rest[1], r)
        default:
            throw notFound(r.path)
        }
    }

    // MARK: Auth and request helpers

    private func authenticate(_ r: APIRequest) throws {
        guard let header = r.headers["authorization"], header.hasPrefix("Bearer "), !token.isEmpty,
              Self.constantTimeEqual(String(header.dropFirst("Bearer ".count)), token) else {
            throw OperationError.unauthorized()
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func allow(_ r: APIRequest, _ methods: String...) throws {
        guard methods.contains(r.method) else {
            throw OperationError(code: "method_not_allowed", message: "\(r.method) is not supported here.", details: ["allowed_methods": methods])
        }
    }

    private func notFound(_ path: String) -> OperationError {
        OperationError(code: "not_found", message: "No endpoint at \(path). See GET /v1/tools and docs/API.md.")
    }

    private func checkQuery(_ r: APIRequest, allowed: Set<String>) throws {
        if let unknown = r.query.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw OperationError.invalidField(unknown, "Unknown query parameter \(unknown).", allowed: allowed.sorted())
        }
    }

    private func body(_ r: APIRequest, allowEmpty: Bool = false) throws -> [String: Any] {
        if r.body.isEmpty {
            if allowEmpty { return [:] }
            throw OperationError.badRequest("A JSON object body is required.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: r.body), let dict = object as? [String: Any] else {
            throw OperationError.badRequest("The body is not a JSON object.")
        }
        return dict
    }

    private func checkKeys(_ body: [String: Any], _ allowed: [String], hint: String = "") throws {
        if let unknown = body.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw OperationError.invalidField(unknown, "Unknown key \(unknown).\(hint)", allowed: allowed)
        }
    }

    /// The envelope fields a request may carry. Authorship is always `api`; nothing in a request can change it.
    private func context(_ body: [String: Any]) throws -> OperationContext {
        var context = OperationContext(author: .api)
        for key in ["source_chat_id", "idempotency_key"] {
            guard let raw = body[key], !(raw is NSNull) else { continue }
            guard let s = raw as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OperationError.invalidField(key, "\(key) must be a non-empty string when given.")
            }
            if key == "source_chat_id" { context.sourceChatID = s } else { context.idempotencyKey = s }
        }
        if let raw = body["expected_revision"], !(raw is NSNull) {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() else {
                throw OperationError.invalidField("expected_revision", "expected_revision must be an integer.")
            }
            context.expectedRevision = n.intValue
        }
        return context
    }

    private func int(_ r: APIRequest, _ key: String) throws -> Int? {
        guard let raw = r.query[key] else { return nil }
        guard let n = Int(raw) else { throw OperationError.invalidField(key, "\(key) must be an integer.") }
        return n
    }

    // MARK: Shared operations

    private func discovery() -> [String: Any] {
        [
            "api_version": Self.version,
            "invoke": "POST /v1/tools/{name} with {\"arguments\": {...}, \"expected_revision\"?, \"idempotency_key\"?, \"source_chat_id\"?}",
            "request_schema": Schema.object([
                "arguments": Schema.object([:], required: [], closed: false),
                "expected_revision": Schema.integer("Only for operations that change an existing item or project; see each operation's expected_revision."),
                "idempotency_key": Schema.string("For mutations: replaying the same request returns the original response without repeating it."),
                "source_chat_id": Schema.string("Recorded on the audit entries the request writes."),
            ], required: []),
            "envelope_schema": OperationRegistry.envelopeSchema,
            "error_schema": Schema.error,
            "statuses": statusTable(),
            "operations": OperationRegistry.all.map(\.discovery),
        ]
    }

    private func statusTable() -> [String: Any] {
        ["values": ItemStatus.allCases.map { ["value": $0.rawValue, "alias": $0.label(for: .experiment), "open": $0.isOpen] },
         "aliases": Dictionary(uniqueKeysWithValues: StatusName.aliases.map { ($0.key, $0.value.rawValue) })]
    }

    private func invoke(_ name: String, _ r: APIRequest) throws -> APIResponse {
        let body = try body(r, allowEmpty: true)
        try checkKeys(body, ["arguments", "expected_revision", "idempotency_key", "source_chat_id"])
        var arguments: [String: Any] = [:]
        if let raw = body["arguments"], !(raw is NSNull) {
            guard let dict = raw as? [String: Any] else {
                throw OperationError.invalidField("arguments", "arguments must be a JSON object.")
            }
            arguments = dict
        }
        let response = service.invoke(name, arguments, context: try context(body))
        return .json(response.error?.httpStatus ?? 200, response.body)
    }

    /// Runs an operation for a v1 endpoint. Errors keep their v1 codes: a missing item is `task_not_found`, and a
    /// revision conflict carries the task in its v1 shape.
    private func call(_ name: String, _ arguments: [String: Any], _ context: OperationContext) throws -> (result: [String: Any], replayed: Bool) {
        let response = service.invoke(name, arguments, context: context)
        if var error = response.error {
            if error.code == "item_not_found" {
                let id = error.details["item_id"] as? String ?? ""
                error = OperationError(code: "task_not_found", message: "No task with id \(id).", details: ["task_id": id])
            } else if error.code == "revision_conflict", let item = error.details["item"] as? [String: Any], let id = item["id"] as? String {
                var details = error.details
                details.removeValue(forKey: "item")
                details["task"] = try legacyTask(id, logLimit: 0)
                error = OperationError(code: error.code, message: error.message, details: details)
            }
            throw error
        }
        return (response.body["result"] as? [String: Any] ?? [:], response.replayed)
    }

    // MARK: v1 endpoints

    private func statuses() -> APIResponse {
        .json(200, [
            "statuses": ItemStatus.allCases.map { ["name": Self.statusName($0), "open": $0.isOpen] },
            "canonical": statusTable(),
            "outcomes": ExperimentOutcome.allCases.map(\.rawValue),
            "updatable_fields": OperationRegistry.named("update_item")!.argumentNames.filter { $0 != "id" },
            "creatable_fields": OperationRegistry.named("create_item")!.argumentNames,
            "kinds": ItemKind.allCases.map(\.rawValue),
            "project_types": ProjectType.allCases.map(\.rawValue),
            "project_statuses": ProjectStatus.allCases.map(\.rawValue),
            "project_fields": OperationRegistry.named("create_project")!.argumentNames,
        ])
    }

    private func listProjects(_ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["include_archived"])
        let result = try call("list_projects", ["include_archived": r.query["include_archived"] == "true"], OperationContext(author: .api)).result
        return .json(200, ["projects": result["projects"] ?? []])
    }

    private func createProject(_ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        try checkKeys(body, ["fields", "source_chat_id", "idempotency_key"], hint: " Put project fields under `fields`.")
        guard let fields = body["fields"] as? [String: Any] else {
            throw OperationError.invalidField("fields", "`fields` must be an object of project fields; `name` is required.",
                                              allowed: OperationRegistry.named("create_project")!.argumentNames)
        }
        let (result, replayed) = try call("create_project", fields, try context(body))
        let id = (result["project"] as? [String: Any])?["id"] as? String
        let current: Any = store.project(id).map(service.serializer.project) ?? result["project"] ?? NSNull()
        return .json(replayed ? 200 : 201, ["project": current, "duplicate": replayed])
    }

    private func listTasks(_ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["project_id", "title", "chat_id", "status", "kind", "limit"])
        var args: [String: Any] = ["status": r.query["status"] ?? "any", "sort": "updated", "limit": try int(r, "limit") ?? 100]
        for key in ["project_id", "title", "chat_id", "kind"] { if let v = r.query[key] { args[key] = v } }
        let result = try call("list_items", args, OperationContext(author: .api)).result
        let ids = (result["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return .json(200, ["total": result["total"] ?? 0, "tasks": ids.compactMap { store.item($0) }.map(legacySummary)])
    }

    private func getTask(_ id: String, _ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["log_limit"])
        let logLimit = min(max(try int(r, "log_limit") ?? 50, 1), Self.maxLogLimit)
        _ = try call("get_item", ["id": id, "log_limit": logLimit], OperationContext(author: .api))
        return .json(200, ["task": try legacyTask(id, logLimit: logLimit)])
    }

    /// v1 semantics on top of create_item: `kind` defaults to experiment (or the project's kind for personal and misc
    /// projects), and `project_id: null` means no project.
    private func createTask(_ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        try checkKeys(body, ["fields", "source_chat_id", "idempotency_key"], hint: " Put task fields under `fields`.")
        guard var fields = body["fields"] as? [String: Any] else {
            throw OperationError.invalidField("fields", "`fields` must be an object of task fields; `title` is required.",
                                              allowed: OperationRegistry.named("create_item")!.argumentNames)
        }
        if fields["project_id"] is NSNull { fields.removeValue(forKey: "project_id") }
        if fields["kind"] == nil || fields["kind"] is NSNull {
            let type = store.project(fields["project_id"] as? String)?.type ?? .research
            fields["kind"] = (type == .research ? ItemKind.experiment : type.defaultKind).rawValue
        }
        let (result, replayed) = try call("create_item", fields, try context(body))
        let id = (result["item"] as? [String: Any])?["id"] as? String ?? ""
        return .json(replayed ? 200 : 201, ["task": try legacyTask(id, logLimit: 50), "duplicate": replayed])
    }

    private func updateTask(_ id: String, _ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        try checkKeys(body, ["fields", "expected_revision", "idempotency_key", "source_chat_id"], hint: " Put task fields under `fields`.")
        guard var fields = body["fields"] as? [String: Any] else {
            throw OperationError.invalidField("fields", "`fields` must be an object of task fields to change.",
                                              allowed: OperationRegistry.named("update_item")!.argumentNames.filter { $0 != "id" })
        }
        if fields["id"] != nil { throw OperationError.invalidField("id", "The task id goes in the URL, not in `fields`.") }
        if fields["project_id"] is NSNull { fields["project_id"] = "" }
        let requested = fields.keys.sorted()
        fields["id"] = id
        let (result, _) = try call("update_item", fields, try context(body))
        let changedFields = Set(result["changed"] as? [String] ?? [])
        let fieldFor = ["progress": "progress_current", "progress_add": "progress_current", "append_notes": "notes"]
        let changed = requested.filter { changedFields.contains(fieldFor[$0] ?? $0) }
        return .json(200, ["task": try legacyTask(id, logLimit: 50), "changed": changed])
    }

    /// Appends a textual progress-log entry. It never changes a progress count; that is update_item's `progress_add`.
    private func appendProgress(_ id: String, _ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        let keys = ["text", "source_chat_id", "idempotency_key"]
        try checkKeys(body, keys)
        for key in keys {
            guard let s = body[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OperationError.invalidField(key, "\(key) is required and must be a non-empty string.")
            }
        }
        let (result, replayed) = try call("add_log", ["item_id": id, "text": body["text"]!], try context(body))
        let entryID = (result["log_entry"] as? [String: Any])?["id"] as? String
        guard let entry = store.logs(forItem: id, limit: Self.maxLogLimit).first(where: { $0.id == entryID }),
              let saved = try store.storedItem(id) else {
            throw OperationError(code: "storage_error", message: "The entry was not found after saving.")
        }
        return .json(replayed ? 200 : 201, ["entry": Self.legacyLog(entry), "duplicate": replayed, "task_id": id, "revision": saved.revision])
    }

    // MARK: v1 serialization

    /// v1 names statuses by their experiment labels for every kind.
    static func statusName(_ s: ItemStatus) -> String { s.label(for: .experiment) }

    /// The task as stored in the database, in the v1 shape.
    private func legacyTask(_ id: String, logLimit: Int) throws -> [String: Any] {
        guard let i = try store.storedItem(id) else {
            throw OperationError(code: "task_not_found", message: "No task with id \(id).", details: ["task_id": id])
        }
        var d = legacySummary(i)
        d["notes"] = i.notes; d["hypothesis"] = i.hypothesis; d["setup"] = i.setup; d["compute"] = i.compute
        d["results"] = i.results; d["conclusion"] = i.conclusion; d["outcome"] = i.outcome.rawValue
        d["metrics"] = i.metrics.map { ["name": $0.name, "value": $0.value] }
        d["project"] = store.project(i.projectID).map { ["id": $0.id, "name": $0.name, "type": $0.type.rawValue] } ?? NSNull()
        d["created_at"] = Self.iso(i.createdAt)
        d["run_started_at"] = i.runStartedAt.map(Self.iso) ?? NSNull()
        d["run_ended_at"] = i.runEndedAt.map(Self.iso) ?? NSNull()
        // Added with the shared operations, so v1 clients can read checklists and counts too.
        d["checklist"] = i.checklist.map(service.serializer.checklistEntry)
        d["progress_current"] = i.progressCurrent
        d["progress_target"] = i.progressTarget ?? NSNull()
        d["progress_unit"] = i.progressUnit
        d["tracks_progress"] = i.tracksProgress
        if logLimit > 0 { d["progress_log"] = store.logs(forItem: id, limit: logLimit).map(Self.legacyLog) }
        return d
    }

    private func legacySummary(_ i: Item) -> [String: Any] {
        ["id": i.id, "title": i.title, "kind": i.kind.rawValue, "status": Self.statusName(i.status),
         "project_id": i.projectID ?? NSNull(), "chat_ids": i.chatIDs, "revision": i.revision, "updated_at": Self.iso(i.updatedAt)]
    }

    private static func legacyLog(_ l: LogEntry) -> [String: Any] {
        ["id": l.id, "created_at": iso(l.createdAt), "kind": l.kind, "text": l.text, "author": l.author.rawValue,
         "source_chat_id": l.sourceChatID ?? NSNull(), "idempotency_key": l.idempotencyKey ?? NSNull()]
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
