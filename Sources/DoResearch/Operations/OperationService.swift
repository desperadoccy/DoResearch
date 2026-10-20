import Foundation

/// The application service behind every operation. Transports (the assistant's tool loop, the HTTP API) supply an
/// `OperationContext` and get back the same envelope or error JSON:
///
///     {"operation": "update_item", "result": {...}, "replayed": false, "affected": [{"type", "id", "revision"}]}
///
/// Mutations run in one `Store.atomically` group with their audit entries and their idempotency record, so a
/// request either takes full effect or none, and a replayed request is answered from its record.
@MainActor
struct OperationService {
    let store: Store
    var serializer: Serializer { Serializer(store: store) }

    struct Response {
        /// The envelope on success, `{"error": ...}` on failure.
        var body: [String: Any]
        var summary: String
        var error: OperationError?
        var replayed = false
    }

    func invoke(_ name: String, _ arguments: [String: Any], context: OperationContext) -> Response {
        do {
            return try execute(name, arguments, context)
        } catch let error as OperationError {
            return Response(body: error.json, summary: "\(name) failed: \(error.message)", error: error)
        } catch {
            let error = OperationError.storage(error)
            return Response(body: error.json, summary: "\(name) failed: could not save", error: error)
        }
    }

    private func execute(_ name: String, _ arguments: [String: Any], _ context: OperationContext) throws -> Response {
        guard let op = OperationRegistry.named(name) else {
            throw OperationError(code: "unknown_operation", message: "No operation named \(name).",
                                 details: ["operation": name, "allowed": OperationRegistry.all.map(\.name)])
        }
        if let unknown = arguments.keys.sorted().first(where: { !op.argumentNames.contains($0) }) {
            throw OperationError.invalidField(unknown, "Unknown argument \(unknown) for \(name).", allowed: op.argumentNames)
        }
        for (field, value) in [("source_chat_id", context.sourceChatID), ("idempotency_key", context.idempotencyKey)] {
            if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OperationError.invalidField(field, "\(field) must not be empty when given.")
            }
        }
        if context.expectedRevision != nil, op.revisionTarget == nil {
            throw OperationError.invalidField("expected_revision",
                                              "\(name) doesn't take expected_revision; it applies to operations that change an existing item or project.")
        }
        let args = Args(raw: arguments)
        guard op.mutates else {
            let out = try op.run(self, args, context.author)
            return Response(body: envelope(op, out), summary: out.summary)
        }

        // A committed replay is recognized before anything else, so it isn't rejected for the revision it advanced.
        var fingerprint = ""
        if let key = context.idempotencyKey {
            fingerprint = Wire.fingerprint(operation: name, arguments: arguments, sourceChatID: context.sourceChatID)
            if let record = try store.idempotencyRecord(key) {
                guard record.operation == name, record.fingerprint == fingerprint,
                      var body = (try? JSONSerialization.jsonObject(with: Data(record.result.utf8))) as? [String: Any] else {
                    var details: [String: Any] = ["idempotency_key": key]
                    if record.operation != "legacy" { details["original_operation"] = record.operation }
                    throw OperationError(code: "idempotency_conflict",
                                         message: "idempotency_key was already used for a different request"
                                             + (record.operation == "legacy" ? " (with an earlier version of the API)" : "")
                                             + ". Use a new key for new content.",
                                         details: details)
                }
                body["replayed"] = true
                return Response(body: body, summary: "\(name): already applied, not repeated", replayed: true)
            }
        }
        if let expected = context.expectedRevision, let target = op.revisionTarget {
            try checkRevision(target, args, expected: expected)
        }
        return try store.atomically(sourceChatID: context.sourceChatID, idempotencyKey: context.idempotencyKey) {
            let out = try op.run(self, args, context.author)
            let body = envelope(op, out)
            if let key = context.idempotencyKey {
                try store.recordIdempotency(key, .init(operation: name, fingerprint: fingerprint, result: Wire.string(body)))
            }
            return Response(body: body, summary: out.summary)
        }
    }

    private func envelope(_ op: Operation, _ out: OperationOutput) -> [String: Any] {
        let affected = out.affected.map { a -> [String: Any] in
            let revision = a.type == "item" ? store.item(a.id)?.revision : store.project(a.id)?.revision
            return ["type": a.type, "id": a.id, "revision": revision ?? NSNull()]
        }
        return ["operation": op.name, "result": out.result, "replayed": false, "affected": affected]
    }

    private func checkRevision(_ target: Operation.RevisionTarget, _ a: Args, expected: Int) throws {
        switch target {
        case .item(let arg):
            let item = try requireItem(a.requiredString(arg))
            guard item.revision == expected else {
                throw conflict(expected, item.revision, ["item": serializer.detail(item)])
            }
        case .project(let arg):
            let project = try requireProject(a.requiredString(arg))
            guard project.revision == expected else {
                throw conflict(expected, project.revision, ["project": serializer.project(project)])
            }
        }
    }

    private func conflict(_ expected: Int, _ current: Int, _ object: [String: Any]) -> OperationError {
        OperationError(code: "revision_conflict",
                       message: "The object is at revision \(current), not \(expected). Re-read it, reapply your change, and retry.",
                       details: object.merging(["expected_revision": expected, "current_revision": current]) { _, new in new })
    }

    // MARK: Lookup

    func requireItem(_ id: String) throws -> Item {
        guard let item = store.item(id) else { throw OperationError.itemNotFound(id) }
        return item
    }

    func requireProject(_ id: String) throws -> Project {
        guard let project = store.project(id) else { throw OperationError.projectNotFound(id) }
        return project
    }

    /// The item as stored in the database, so results double as verification of the write.
    private func persisted(_ id: String) throws -> Item {
        guard let item = try store.storedItem(id) else {
            throw OperationError(code: "storage_error", message: "Item \(id) was not found after saving.")
        }
        return item
    }

    private func persistedProject(_ id: String) throws -> Project {
        guard let project = try store.storedProject(id) else {
            throw OperationError(code: "storage_error", message: "Project \(id) was not found after saving.")
        }
        return project
    }

    /// Log entries returned with an item after a write.
    private static let writeLogLimit = 5
}

// MARK: - Items

extension OperationService {
    func listItems(_ a: Args) throws -> OperationOutput {
        let kind = try a.enumValue("kind", ItemKind.self)
        let statusFilter = try a.string("status") ?? "open"
        let projectID = try a.string("project_id")
        let area = try a.enumValue("area", ProjectType.self)
        let query = try a.string("query")?.trimmingCharacters(in: .whitespaces).lowercased()
        let title = try a.string("title")?.trimmingCharacters(in: .whitespaces)
        let chatID = try a.string("chat_id")
        let todayOnly = try a.bool("today") ?? false
        let sort = try a.string("sort") ?? "priority"
        let limit = min(max(try a.int("limit") ?? 50, 1), 500)

        var list = todayOnly ? store.items(for: .today) : store.items
        if let kind { list = list.filter { $0.kind == kind } }
        if let area { list = list.filter { store.type(of: $0) == area } }
        switch statusFilter.lowercased() {
        case "open": list = list.filter { $0.status.isOpen }
        case "closed": list = list.filter { !$0.status.isOpen }
        case "any": break
        default:
            guard let s = StatusName.parse(statusFilter) else { throw StatusName.invalid("status", statusFilter) }
            list = list.filter { $0.status == s }
        }
        if let projectID {
            if projectID == "none" {
                list = list.filter { $0.projectID == nil }
            } else {
                _ = try requireProject(projectID)
                list = list.filter { $0.projectID == projectID }
            }
        }
        if let query, !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || $0.notes.lowercased().contains(query)
                    || $0.tags.contains { $0.lowercased().contains(query) }
            }
        }
        if let title, !title.isEmpty { list = list.filter { $0.title.localizedCaseInsensitiveContains(title) } }
        if let chatID { list = list.filter { $0.chatIDs.contains(chatID) } }
        switch sort {
        case "priority": list.sort(by: Store.sortKey)
        case "updated": list.sort { $0.updatedAt > $1.updatedAt }
        case "manual": list.sort(by: Store.manualOrder)
        default: throw OperationError.invalidField("sort", "Unknown sort \(sort).", allowed: ["priority", "updated", "manual"])
        }
        let total = list.count
        return OperationOutput(result: ["total": total, "items": list.prefix(limit).map(serializer.summary)],
                               summary: "Looked up \(total) item\(total == 1 ? "" : "s")")
    }

    func getItem(_ a: Args) throws -> OperationOutput {
        let item = try requireItem(a.requiredString("id"))
        let logLimit = min(max(try a.int("log_limit") ?? 25, 1), 500)
        let stored = try persisted(item.id)
        return OperationOutput(result: ["item": serializer.detail(stored, logLimit: logLimit)], summary: "Read “\(item.title)”")
    }

    func createItem(_ a: Args, _ author: Author) throws -> OperationOutput {
        let title = try a.requiredText("title")
        guard a.has("kind") else { throw OperationError.invalidField("kind", "kind is required.", allowed: OperationRegistry.kinds) }
        var draft = Item(id: "", title: title)
        try applyFields(a, to: &draft)
        let steps = try (a.stringArray("checklist") ?? []).map { step in
            let t = step.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw OperationError.invalidField("checklist", "Checklist steps must not be empty.") }
            return t
        }
        // Without a chosen status, a new item's count moves its status as it would on an existing item.
        if !a.has("status") { Store.applyInitialProgress(&draft) }
        let created = try store.insertItem(draft, checklist: steps, author: author)
        let saved = try persisted(created.id)
        return OperationOutput(result: ["item": serializer.detail(saved, logLimit: Self.writeLogLimit)],
                               summary: "Created \(saved.kind.label.lowercased()) “\(saved.title)”", affected: [("item", saved.id)])
    }

    func updateItem(_ a: Args, _ author: Author) throws -> OperationOutput {
        let current = try requireItem(a.requiredString("id"))
        var item = current
        try applyFields(a, to: &item)
        if let extra = try a.string("append_notes"), !extra.isEmpty {
            item.notes = item.notes.isEmpty ? extra : item.notes + "\n\n" + extra
        }
        let log = try a.string("log")?.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.saveItem(item, author: author)
        if let log, !log.isEmpty { try store.appendNote(log, itemID: item.id, author: author) }
        let saved = try persisted(item.id)
        let before = serializer.detail(current), after = serializer.detail(saved)
        let changed = Self.itemFieldKeys.filter { !Self.same(before[$0], after[$0]) }
        return OperationOutput(result: ["item": serializer.detail(saved, logLimit: Self.writeLogLimit), "changed": changed],
                               summary: "Updated “\(saved.title)”", affected: [("item", saved.id)])
    }

    private static let itemFieldKeys = [
        "title", "kind", "status", "priority", "project_id", "notes", "due_date", "today", "tags", "repo", "branch", "link",
        "hypothesis", "setup", "compute", "results", "conclusion", "outcome", "metrics", "run_started_at", "run_ended_at",
        "progress_current", "progress_target", "progress_unit", "chat_ids", "completed_at",
    ]

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? NSObject else { return b == nil }
        return a.isEqual(b)
    }

    /// Fields shared by create_item and update_item. Validates everything on a copy; nothing is saved here.
    private func applyFields(_ a: Args, to item: inout Item) throws {
        if a.has("title") { item.title = try a.requiredText("title") }
        if let v = try a.enumValue("kind", ItemKind.self) { item.kind = v }
        if let v = try a.string("status") {
            guard let s = StatusName.parse(v) else { throw StatusName.invalid("status", v) }
            item.status = s
        }
        if let v = try a.string("priority") {
            guard let p = Priority.allCases.first(where: { $0.name == v.lowercased() }) else {
                throw OperationError.invalidField("priority", "Invalid priority \(v).", allowed: Priority.allCases.map(\.name))
            }
            item.priority = p
        }
        if let v = try a.string("project_id") {
            if v.isEmpty || v == "none" {
                item.projectID = nil
            } else {
                guard store.project(v) != nil else {
                    throw OperationError.invalidField("project_id", "No project with id \(v). Call list_projects, or pass an empty string for no project.")
                }
                item.projectID = v
            }
        }
        if let v = try a.string("notes") { item.notes = v }
        switch try a.date("due_date") {
        case .set(let d): item.dueDate = Calendar.current.startOfDay(for: d)
        case .clear: item.dueDate = nil
        case .absent: break
        }
        if let v = try a.bool("today") { item.flaggedToday = v }
        if let v = try a.stringArray("tags") { item.tags = v }
        if let v = try a.string("repo") { item.repo = v }
        if let v = try a.string("branch") { item.branch = v }
        if let v = try a.string("link") { item.link = v }
        if let v = try a.string("hypothesis") { item.hypothesis = v }
        if let v = try a.string("setup") { item.setup = v }
        if let v = try a.string("compute") { item.compute = v }
        if let v = try a.string("results") { item.results = v }
        if let v = try a.string("conclusion") { item.conclusion = v }
        if let v = try a.enumValue("outcome", ExperimentOutcome.self) { item.outcome = v }
        if let raw = a.raw["metrics"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { throw OperationError.invalidField("metrics", "metrics must be an array of {name, value}.") }
            item.metrics = try list.map { element in
                guard let m = element as? [String: Any], let name = m["name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw OperationError.invalidField("metrics", "Each metric needs a non-empty string name.")
                }
                if let s = m["value"] as? String { return Metric(name: name, value: s) }
                if let n = m["value"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return Metric(name: name, value: n.stringValue) }
                throw OperationError.invalidField("metrics", "Metric \(name) needs a string or number value.")
            }
        }
        switch try a.date("run_started_at") {
        case .set(let d): item.runStartedAt = d
        case .clear: item.runStartedAt = nil
        case .absent: break
        }
        switch try a.date("run_ended_at") {
        case .set(let d): item.runEndedAt = d
        case .clear: item.runEndedAt = nil
        case .absent: break
        }
        if let v = try a.int("progress_target") {
            guard v >= 0 else { throw OperationError.invalidField("progress_target", "progress_target must be a positive integer, or 0 to stop tracking.") }
            item.progressTarget = v > 0 ? v : nil
        }
        if let v = try a.string("progress_unit") { item.progressUnit = v }
        let current = try a.int("progress"), delta = try a.int("progress_add")
        if current != nil || delta != nil {
            guard item.tracksProgress else {
                throw OperationError.invalidField(current != nil ? "progress" : "progress_add",
                                                  "Set progress_target before reporting progress on this item (it can be in the same request).")
            }
            if let current {
                guard current >= 0 else { throw OperationError.invalidField("progress", "progress must be 0 or more.") }
                item.progressCurrent = current
            }
            if let delta { item.progressCurrent = max(item.progressCurrent + delta, 0) }
        }
        if let ids = try a.stringArray("chat_ids") {
            guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw OperationError.invalidField("chat_ids", "chat_ids must be non-empty strings.")
            }
            item.chatIDs = ids.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        }
    }

    func updateChecklist(_ a: Args, _ author: Author) throws -> OperationOutput {
        let item = try requireItem(a.requiredString("item_id"))
        let add = try (a.stringArray("add") ?? []).map { title in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw OperationError.invalidField("add", "Checklist steps must not be empty.") }
            return t
        }

        // Resolve every reference against the checklist as it is before the request, and reject the whole request
        // if any of them is missing, ambiguous, or contradicts another.
        func resolve(_ field: String) throws -> [String] {
            var ids: [String] = []
            for key in try a.stringArray(field) ?? [] {
                let id: String
                if let byID = item.checklist.first(where: { $0.id == key }) {
                    id = byID.id
                } else {
                    let matches = item.checklist.filter { $0.title.lowercased() == key.lowercased() }
                    if matches.isEmpty {
                        throw OperationError(code: "checklist_entry_not_found",
                                             message: "No checklist step matching “\(key)” on item \(item.id).",
                                             details: ["field": field, "step": key, "item_id": item.id])
                    }
                    guard matches.count == 1 else {
                        throw OperationError(code: "ambiguous_match",
                                             message: "\(matches.count) checklist steps are titled “\(key)”. Refer to one by id.",
                                             details: ["field": field, "step": key,
                                                       "candidates": matches.map { ["id": $0.id, "title": $0.title] }])
                    }
                    id = matches[0].id
                }
                if !ids.contains(id) { ids.append(id) }
            }
            return ids
        }
        let check = try resolve("check"), uncheck = try resolve("uncheck"), remove = try resolve("remove")
        for (first, second, x, y) in [("check", "uncheck", check, uncheck), ("remove", "check", remove, check), ("remove", "uncheck", remove, uncheck)] {
            let both = x.filter(y.contains)
            if !both.isEmpty {
                throw OperationError(code: "contradictory_operations",
                                     message: "The same step can't be in both \(first) and \(second).",
                                     details: ["fields": [first, second], "steps": both])
            }
        }

        let added = try store.applyChecklist(item.id, .init(add: add, check: check, uncheck: uncheck, remove: remove), author: author)
        let saved = try persisted(item.id)
        let p = saved.checklistProgress
        return OperationOutput(
            result: ["item_id": item.id, "revision": saved.revision, "changed": saved.revision != item.revision,
                     "checklist": saved.checklist.map(serializer.checklistEntry), "added": added.map(serializer.checklistEntry)],
            summary: "Checklist of “\(saved.title)”: \(p.done)/\(p.total) done", affected: [("item", item.id)])
    }

    func addLog(_ a: Args, _ author: Author) throws -> OperationOutput {
        let item = try requireItem(a.requiredString("item_id"))
        let text = try a.requiredText("text")
        let entry = try store.appendNote(text, itemID: item.id, author: author)
        let saved = try persisted(item.id)
        return OperationOutput(result: ["item_id": item.id, "revision": saved.revision, "log_entry": serializer.logEntry(entry)],
                               summary: "Logged progress on “\(item.title)”", affected: [("item", item.id)])
    }
}

// MARK: - Projects and review

extension OperationService {
    func listProjects(_ a: Args) throws -> OperationOutput {
        let includeArchived = try a.bool("include_archived") ?? false
        let type = try a.enumValue("type", ProjectType.self)
        let list = store.projects.filter { (includeArchived || $0.status != .archived) && (type == nil || $0.type == type) }
        return OperationOutput(result: ["projects": list.map(serializer.project)],
                               summary: "Looked up \(list.count) project\(list.count == 1 ? "" : "s")")
    }

    func createProject(_ a: Args, _ author: Author) throws -> OperationOutput {
        let name = try a.requiredText("name")
        let type = try a.enumValue("type", ProjectType.self) ?? .research
        var draft = Project(id: "", name: name, type: type)
        try applyProjectFields(a, to: &draft)
        try checkUniqueName(draft)
        let created = try store.insertProject(draft, author: author)
        let saved = try persistedProject(created.id)
        return OperationOutput(result: ["project": serializer.project(saved)],
                               summary: "Created \(saved.type.label.lowercased()) project “\(saved.name)”", affected: [("project", saved.id)])
    }

    func updateProject(_ a: Args, _ author: Author) throws -> OperationOutput {
        let current = try requireProject(a.requiredString("id"))
        var p = current
        if a.has("name") { p.name = try a.requiredText("name") }
        if let v = try a.enumValue("type", ProjectType.self) { p.type = v }
        try applyProjectFields(a, to: &p)
        try checkUniqueName(p)
        try store.saveProject(p, author: author)
        let saved = try persistedProject(p.id)
        let before = serializer.project(current), after = serializer.project(saved)
        let changed = ["name", "type", "status", "summary", "deadline", "color", "symbol"].filter { !Self.same(before[$0], after[$0]) }
        return OperationOutput(result: ["project": serializer.project(saved), "changed": changed],
                               summary: "Updated project “\(saved.name)”", affected: [("project", saved.id)])
    }

    private func applyProjectFields(_ a: Args, to p: inout Project) throws {
        if let v = try a.string("summary") { p.summary = v }
        if let v = try a.enumValue("status", ProjectStatus.self) { p.status = v }
        switch try a.date("deadline") {
        case .set(let d): p.deadline = Calendar.current.startOfDay(for: d)
        case .clear: p.deadline = nil
        case .absent: break
        }
        if let v = try a.string("color") {
            guard Project.palette.contains(v) else { throw OperationError.invalidField("color", "Unknown color \(v).", allowed: Project.palette) }
            p.color = v
        }
        if let v = try a.string("symbol") {
            guard Project.symbols.contains(v) else { throw OperationError.invalidField("symbol", "Unknown symbol \(v).", allowed: Project.symbols) }
            p.symbol = v
        }
    }

    /// Names are unique among non-archived projects, ignoring case.
    private func checkUniqueName(_ p: Project) throws {
        guard p.status != .archived,
              let same = store.projects.first(where: { $0.id != p.id && $0.status != .archived && $0.name.caseInsensitiveCompare(p.name) == .orderedSame })
        else { return }
        throw OperationError(code: "project_exists",
                             message: "A project named “\(same.name)” already exists. Use its id, or pick another name.",
                             details: ["project": serializer.project(same)])
    }

    func reviewSummary(_ a: Args) throws -> OperationOutput {
        let days = min(max(try a.int("days") ?? 7, 1), 90)
        let s = store.review(days: days)
        let result: [String: Any] = [
            "window": ["days": days, "since": Wire.day(s.since), "today": Wire.day(Date())],
            "completed": s.completed.map(serializer.summary),
            "created_count": s.created.count,
            "experiments": [
                "running": s.runningExperiments.map(serializer.experimentBrief),
                "analyzing": s.analyzingExperiments.map(serializer.experimentBrief),
                "concluded_in_window": s.concludedExperiments.map(serializer.experimentBrief),
                "planned": s.plannedExperiments.map(serializer.summary),
            ],
            "coding_active": s.activeCoding.map(serializer.summary),
            "blocked": s.blocked.map(serializer.summary),
            "overdue": s.overdue.map(serializer.summary),
            "stale": s.stale.map(serializer.summary),
            "stale_after_days": ReviewSummary.staleAfterDays,
            "activity": s.logs.prefix(120).map { log -> [String: Any] in
                ["created_at": Wire.time(log.createdAt), "item_id": log.itemID ?? NSNull(), "project_id": log.projectID ?? NSNull(),
                 "title": store.item(log.itemID)?.title ?? store.project(log.projectID)?.name ?? "",
                 "kind": log.kind, "author": log.author.rawValue, "text": log.text]
            },
        ]
        return OperationOutput(result: result, summary: "Gathered \(days)-day review")
    }
}
