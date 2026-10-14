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
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return APIResponse(status: status, body: data)
    }
}

/// An error with a stable `code` clients can branch on. Serialized as `{"error": {"code", "message", ...details}}`.
struct APIError: Error {
    let status: Int
    let code: String
    let message: String
    var details: [String: Any] = [:]

    static func unauthorized() -> APIError {
        APIError(status: 401, code: "unauthorized", message: "Missing or invalid bearer token. Send `Authorization: Bearer <token>`.")
    }
    static func taskNotFound(_ id: String) -> APIError {
        APIError(status: 404, code: "task_not_found", message: "No task with id \(id).", details: ["task_id": id])
    }
    static func invalidField(_ field: String, _ message: String, allowed: [String]? = nil) -> APIError {
        var details: [String: Any] = ["field": field]
        if let allowed { details["allowed"] = allowed }
        return APIError(status: 422, code: "invalid_field", message: message, details: details)
    }
    static func badRequest(_ message: String) -> APIError {
        APIError(status: 400, code: "bad_request", message: message)
    }
    static func storage(_ error: Error) -> APIError {
        APIError(status: 500, code: "storage_error", message: "The change could not be saved: \(error.localizedDescription)")
    }

    var response: APIResponse {
        var body = details
        body["code"] = code
        body["message"] = message
        return .json(status, ["error": body])
    }
}

/// The local task API (docs/API.md). Runs on the main actor and changes data only through `Store`, like the UI and
/// the assistant, so edits show up in the app at once and a revision check and its write can't interleave with UI edits.
@MainActor
struct TaskAPI {
    let store: Store
    let token: String

    static let version = 1
    static let maxLogLimit = 500

    /// Experiment status names; the API uses them for every kind of item.
    static func statusName(_ s: ItemStatus) -> String { s.label(for: .experiment) }
    static let statusNames = ItemStatus.allCases.map(statusName)
    static let outcomeNames = ExperimentOutcome.allCases.map(\.rawValue)
    static let updatableFields = ["title", "status", "project_id", "notes", "hypothesis", "setup", "compute", "results",
                                  "conclusion", "outcome", "metrics", "chat_ids"]
    /// `kind` can be chosen only when creating a task.
    static let creatableFields = ["kind"] + updatableFields

    func handle(_ request: APIRequest) -> APIResponse {
        do {
            return try route(request)
        } catch let error as APIError {
            return error.response
        } catch {
            return APIError.storage(error).response
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
        case 1 where rest[0] == "statuses":
            try allow(r, "GET")
            return statuses()
        case 1 where rest[0] == "projects":
            try allow(r, "GET")
            return try listProjects(r)
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

    // MARK: Auth and routing helpers

    private func authenticate(_ r: APIRequest) throws {
        guard let header = r.headers["authorization"], header.hasPrefix("Bearer "), !token.isEmpty,
              Self.constantTimeEqual(String(header.dropFirst("Bearer ".count)), token) else {
            throw APIError.unauthorized()
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func allow(_ r: APIRequest, _ methods: String...) throws {
        guard methods.contains(r.method) else {
            throw APIError(status: 405, code: "method_not_allowed", message: "\(r.method) is not supported here.",
                           details: ["allowed_methods": methods])
        }
    }

    private func notFound(_ path: String) -> APIError {
        APIError(status: 404, code: "not_found", message: "No endpoint at \(path). See docs/API.md.")
    }

    private func checkQuery(_ r: APIRequest, allowed: Set<String>) throws {
        if let unknown = r.query.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw APIError.invalidField(unknown, "Unknown query parameter \(unknown).", allowed: allowed.sorted())
        }
    }

    private func body(_ r: APIRequest) throws -> [String: Any] {
        guard !r.body.isEmpty else { throw APIError.badRequest("A JSON object body is required.") }
        guard let object = try? JSONSerialization.jsonObject(with: r.body), let dict = object as? [String: Any] else {
            throw APIError.badRequest("The body is not a JSON object.")
        }
        return dict
    }

    private func limit(_ r: APIRequest, _ key: String, default value: Int, max: Int) throws -> Int {
        guard let raw = r.query[key] else { return value }
        guard let n = Int(raw), n >= 1 else { throw APIError.invalidField(key, "\(key) must be a positive integer.") }
        return min(n, max)
    }

    private func status(named name: String, field: String) throws -> ItemStatus {
        if let s = ItemStatus.allCases.first(where: { Self.statusName($0).caseInsensitiveCompare(name) == .orderedSame }) { return s }
        throw APIError.invalidField(field,
                                    "Unknown status “\(name)”. `status` is the experiment status; record chat execution state "
                                        + "(running, completed, failed) in a progress log entry instead.",
                                    allowed: Self.statusNames)
    }

    private func requireItem(_ id: String) throws -> Item {
        guard let item = store.item(id) else { throw APIError.taskNotFound(id) }
        return item
    }

    // MARK: Endpoints

    private func statuses() -> APIResponse {
        .json(200, [
            "statuses": ItemStatus.allCases.map { ["name": Self.statusName($0), "open": $0.isOpen] },
            "outcomes": Self.outcomeNames,
            "updatable_fields": Self.updatableFields,
            "creatable_fields": Self.creatableFields,
            "kinds": ItemKind.allCases.map(\.rawValue),
        ])
    }

    private func listProjects(_ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["include_archived"])
        let includeArchived = r.query["include_archived"] == "true"
        let list = store.projects.filter { includeArchived || $0.status != .archived }
        return .json(200, ["projects": list.map { p -> [String: Any] in
            ["id": p.id, "name": p.name, "type": p.type.rawValue, "status": p.status.rawValue]
        }])
    }

    private func listTasks(_ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["project_id", "title", "chat_id", "status", "kind", "limit"])
        var list = store.items
        if let pid = r.query["project_id"] {
            if pid == "none" {
                list = list.filter { $0.projectID == nil }
            } else {
                guard store.project(pid) != nil else {
                    throw APIError(status: 404, code: "project_not_found", message: "No project with id \(pid).", details: ["project_id": pid])
                }
                list = list.filter { $0.projectID == pid }
            }
        }
        if let title = r.query["title"]?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(title) }
        }
        if let chat = r.query["chat_id"] { list = list.filter { $0.chatIDs.contains(chat) } }
        if let name = r.query["status"] {
            let s = try status(named: name, field: "status")
            list = list.filter { $0.status == s }
        }
        if let raw = r.query["kind"] {
            guard let kind = ItemKind(rawValue: raw) else {
                throw APIError.invalidField("kind", "Unknown kind \(raw).", allowed: ItemKind.allCases.map(\.rawValue))
            }
            list = list.filter { $0.kind == kind }
        }
        list.sort { $0.updatedAt > $1.updatedAt }
        let max = try limit(r, "limit", default: 100, max: 500)
        return .json(200, ["total": list.count, "tasks": list.prefix(max).map(summary)])
    }

    private func getTask(_ id: String, _ r: APIRequest) throws -> APIResponse {
        try checkQuery(r, allowed: ["log_limit"])
        let logLimit = try limit(r, "log_limit", default: 50, max: Self.maxLogLimit)
        return .json(200, ["task": try stored(id, logLimit: logLimit)])
    }

    private func updateTask(_ id: String, _ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        if let unknown = body.keys.sorted().first(where: { $0 != "fields" && $0 != "expected_revision" }) {
            throw APIError.invalidField(unknown, "Unknown key \(unknown). Put task fields under `fields`.",
                                        allowed: ["expected_revision", "fields"])
        }
        guard let fields = body["fields"] as? [String: Any] else {
            throw APIError.invalidField("fields", "`fields` must be an object of task fields to change.", allowed: Self.updatableFields)
        }
        var expected: Int?
        if let raw = body["expected_revision"], !(raw is NSNull) {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue) else {
                throw APIError.invalidField("expected_revision", "expected_revision must be an integer.")
            }
            expected = n.intValue
        }

        let current = try requireItem(id)
        if let expected, expected != current.revision {
            throw APIError(status: 409, code: "revision_conflict",
                           message: "The task is at revision \(current.revision), not \(expected). Re-read it, reapply your change, and retry.",
                           details: ["expected_revision": expected, "current_revision": current.revision,
                                     "task": try stored(id, logLimit: 0)])
        }
        var item = current
        for key in fields.keys.sorted() {
            try apply(key, fields[key]!, to: &item)
        }
        do {
            try store.saveItem(item, author: .api)
        } catch {
            throw APIError.storage(error)
        }
        let saved = try stored(id, logLimit: 50)
        let changed = fields.keys.sorted().filter { key in
            Self.fieldValue(key, current) != Self.fieldValue(key, store.item(id) ?? current)
        }
        return .json(200, ["task": saved, "changed": changed])
    }

    private func apply(_ key: String, _ value: Any, to item: inout Item) throws {
        func string() throws -> String {
            guard let s = value as? String else { throw APIError.invalidField(key, "\(key) must be a string.") }
            return s
        }
        switch key {
        case "title":
            let t = try string().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw APIError.invalidField(key, "title must not be empty.") }
            item.title = t
        case "status": item.status = try status(named: try string(), field: key)
        case "project_id":
            if value is NSNull {
                item.projectID = nil
            } else {
                let pid = try string()
                guard store.project(pid) != nil else { throw APIError.invalidField(key, "No project with id \(pid). Use null for no project.") }
                item.projectID = pid
            }
        case "notes": item.notes = try string()
        case "hypothesis": item.hypothesis = try string()
        case "setup": item.setup = try string()
        case "compute": item.compute = try string()
        case "results": item.results = try string()
        case "conclusion": item.conclusion = try string()
        case "outcome":
            guard let o = ExperimentOutcome(rawValue: try string()) else {
                throw APIError.invalidField(key, "Unknown outcome.", allowed: Self.outcomeNames)
            }
            item.outcome = o
        case "metrics":
            guard let list = value as? [[String: Any]] else { throw APIError.invalidField(key, "metrics must be an array of {name, value}.") }
            item.metrics = try list.map { m in
                guard let name = m["name"] as? String, !name.isEmpty else { throw APIError.invalidField(key, "Each metric needs a non-empty string name.") }
                if let s = m["value"] as? String { return Metric(name: name, value: s) }
                if let n = m["value"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return Metric(name: name, value: n.stringValue) }
                throw APIError.invalidField(key, "Metric \(name) needs a string or number value.")
            }
        case "chat_ids":
            guard let ids = value as? [String], ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw APIError.invalidField(key, "chat_ids must be an array of non-empty strings (it replaces the current list).")
            }
            item.chatIDs = ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        default:
            throw APIError.invalidField(key, "\(key) is not an updatable field.", allowed: Self.updatableFields)
        }
    }

    private func createTask(_ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        let keys = ["fields", "source_chat_id", "idempotency_key"]
        if let unknown = body.keys.sorted().first(where: { !keys.contains($0) }) {
            throw APIError.invalidField(unknown, "Unknown key \(unknown). Put task fields under `fields`.", allowed: keys)
        }
        guard let fields = body["fields"] as? [String: Any] else {
            throw APIError.invalidField("fields", "`fields` must be an object of task fields; `title` is required.",
                                        allowed: Self.creatableFields)
        }
        func optionalString(_ key: String) throws -> String? {
            guard let raw = body[key], !(raw is NSNull) else { return nil }
            guard let s = raw as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError.invalidField(key, "\(key) must be a non-empty string when given.")
            }
            return s
        }
        let sourceChatID = try optionalString("source_chat_id")
        let key = try optionalString("idempotency_key")
        guard fields["title"] != nil else { throw APIError.invalidField("title", "title is required.") }

        var draft = Item(id: "", title: "", status: .todo)
        for name in fields.keys.sorted() where name != "kind" {
            try apply(name, fields[name]!, to: &draft)
        }
        // Without an explicit kind, a task gets the kind its project's type implies (experiment for research work).
        if let raw = fields["kind"] {
            guard let s = raw as? String, let kind = ItemKind(rawValue: s) else {
                throw APIError.invalidField("kind", "Unknown kind.", allowed: ItemKind.allCases.map(\.rawValue))
            }
            draft.kind = kind
        } else {
            let type = store.project(draft.projectID)?.type ?? .research
            draft.kind = type == .research ? .experiment : type.defaultKind
        }

        if let key, let existing = try store.logEntry(idempotencyKey: key) {
            // The "created" entry records the kind and title the task was created with, so later edits don't matter.
            let createdText = "Created \(draft.kind.label.lowercased()) “\(draft.title)”"
            guard existing.kind == "created", let id = existing.itemID, store.item(id) != nil,
                  existing.sourceChatID == sourceChatID, existing.text == createdText else {
                throw APIError(status: 409, code: "idempotency_conflict",
                               message: "idempotency_key was already used for a different request. Use a new key for a new task.",
                               details: ["existing_entry": Self.logJSON(existing)])
            }
            return .json(200, ["task": try stored(id, logLimit: 50), "duplicate": true])
        }

        let created: Item
        do {
            created = try store.insertItem(draft, author: .api, sourceChatID: sourceChatID, idempotencyKey: key)
        } catch {
            throw APIError.storage(error)
        }
        return .json(201, ["task": try stored(created.id, logLimit: 50), "duplicate": false])
    }

    private func appendProgress(_ id: String, _ r: APIRequest) throws -> APIResponse {
        let body = try body(r)
        let keys = ["text", "source_chat_id", "idempotency_key"]
        if let unknown = body.keys.sorted().first(where: { !keys.contains($0) }) {
            throw APIError.invalidField(unknown, "Unknown key \(unknown).", allowed: keys)
        }
        var values: [String: String] = [:]
        for key in keys {
            guard let s = body[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIError.invalidField(key, "\(key) is required and must be a non-empty string.")
            }
            values[key] = s
        }
        _ = try requireItem(id)
        let result: Store.AppendedLog
        do {
            result = try store.appendProgress(values["text"]!, itemID: id, sourceChatID: values["source_chat_id"]!,
                                              idempotencyKey: values["idempotency_key"]!)
        } catch let conflict as Store.IdempotencyConflict {
            throw APIError(status: 409, code: "idempotency_conflict",
                           message: "idempotency_key was already used for a different entry. Use a new key for new content.",
                           details: ["existing_entry": Self.logJSON(conflict.existing)])
        } catch {
            throw APIError.storage(error)
        }
        guard let saved = try store.storedItem(id),
              store.logs(forItem: id, limit: Self.maxLogLimit).contains(where: { $0.id == result.entry.id }) else {
            throw APIError(status: 500, code: "storage_error", message: "The entry was not found after saving.")
        }
        return .json(result.duplicate ? 200 : 201, [
            "entry": Self.logJSON(result.entry), "duplicate": result.duplicate,
            "task_id": id, "revision": saved.revision,
        ])
    }

    // MARK: Serialization

    /// The task as stored in the database, not as cached in memory, so responses double as verification.
    private func stored(_ id: String, logLimit: Int) throws -> [String: Any] {
        guard let item = try store.storedItem(id) else { throw APIError.taskNotFound(id) }
        var d = summary(item)
        for key in ["notes", "hypothesis", "setup", "compute", "results", "conclusion", "outcome", "metrics"] {
            d[key] = Self.fieldValue(key, item)
        }
        d["project"] = store.project(item.projectID).map { ["id": $0.id, "name": $0.name, "type": $0.type.rawValue] } ?? NSNull()
        d["created_at"] = Self.iso(item.createdAt)
        d["run_started_at"] = item.runStartedAt.map(Self.iso) ?? NSNull()
        d["run_ended_at"] = item.runEndedAt.map(Self.iso) ?? NSNull()
        if logLimit > 0 {
            d["progress_log"] = store.logs(forItem: id, limit: logLimit).map(Self.logJSON)
        }
        return d
    }

    private func summary(_ i: Item) -> [String: Any] {
        ["id": i.id, "title": i.title, "kind": i.kind.rawValue, "status": Self.statusName(i.status),
         "project_id": i.projectID ?? NSNull(), "chat_ids": i.chatIDs, "revision": i.revision, "updated_at": Self.iso(i.updatedAt)]
    }

    /// JSON value of an updatable field, also used to work out which requested fields actually changed.
    private static func fieldValue(_ key: String, _ i: Item) -> NSObject {
        switch key {
        case "title": i.title as NSString
        case "status": statusName(i.status) as NSString
        case "project_id": (i.projectID as NSString?) ?? NSNull()
        case "notes": i.notes as NSString
        case "hypothesis": i.hypothesis as NSString
        case "setup": i.setup as NSString
        case "compute": i.compute as NSString
        case "results": i.results as NSString
        case "conclusion": i.conclusion as NSString
        case "outcome": i.outcome.rawValue as NSString
        case "metrics": i.metrics.map { ["name": $0.name, "value": $0.value] } as NSArray
        case "chat_ids": i.chatIDs as NSArray
        default: NSNull()
        }
    }

    private static func logJSON(_ l: LogEntry) -> [String: Any] {
        ["id": l.id, "created_at": iso(l.createdAt), "kind": l.kind, "text": l.text, "author": l.author.rawValue,
         "source_chat_id": l.sourceChatID ?? NSNull(), "idempotency_key": l.idempotencyKey ?? NSNull()]
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
