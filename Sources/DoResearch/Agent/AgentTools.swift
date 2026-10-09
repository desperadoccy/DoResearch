import Foundation

struct ToolOutcome {
    let result: String
    let summary: String
    let isError: Bool
}

struct ToolInputError: Error {
    let message: String
}

/// The agent's tool surface. Every mutation goes through `Store` with `author: .agent`, so it lands in the progress log.
@MainActor
struct AgentTools {
    let store: Store

    // MARK: Definitions

    private static let kinds = ItemKind.allCases.map(\.rawValue)
    private static let statuses = ItemStatus.allCases.map(\.rawValue)
    private static let priorities = Priority.allCases.map(\.name)
    private static let outcomes = ExperimentOutcome.allCases.map(\.rawValue)

    private static func str(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func strEnum(_ values: [String], _ description: String) -> [String: Any] {
        ["type": "string", "enum": values, "description": description]
    }
    private static let strArray: [String: Any] = ["type": "array", "items": ["type": "string"]]

    private static var itemFields: [String: Any] {
        [
            "title": str("Short, specific title."),
            "kind": strEnum(kinds, "coding = implementation work; experiment = running/evaluating something; writing = paper/report text; reading = papers to read; task = other research work; personal; misc."),
            "status": strEnum(statuses, "inbox = unsorted; todo; in_progress (experiment: running); waiting (experiment: analyzing, coding: in review); blocked; done; dropped (use instead of deleting)."),
            "priority": strEnum(priorities, "Priority."),
            "project_id": str("Project id, or empty string for no project."),
            "notes": str("Free-form notes (replaces existing notes)."),
            "due_date": str("YYYY-MM-DD, or empty string to clear."),
            "today": ["type": "boolean", "description": "Show in the Today list."],
            "tags": merge(strArray, ["description": "Replaces existing tags."]),
            "repo": str("Coding: repository path or URL."),
            "branch": str("Coding: git branch."),
            "link": str("Coding: PR or issue URL."),
            "hypothesis": str("Experiment: what is expected and why."),
            "setup": str("Experiment: config, command, dataset, seeds."),
            "compute": str("Experiment: hardware/cluster used."),
            "results": str("Experiment: observations and results (replaces existing)."),
            "conclusion": str("Experiment: what was learned / next steps."),
            "outcome": strEnum(outcomes, "Experiment: whether the hypothesis held."),
            "metrics": [
                "type": "array",
                "description": "Experiment: metric name/value pairs exactly as reported. Replaces existing metrics.",
                "items": [
                    "type": "object",
                    "properties": ["name": ["type": "string"], "value": ["type": "string"]],
                    "required": ["name", "value"],
                ],
            ],
            "run_started_at": str("Experiment: ISO 8601 datetime, 'now', or empty string to clear."),
            "run_ended_at": str("Experiment: ISO 8601 datetime, 'now', or empty string to clear."),
        ]
    }

    private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        a.merging(b) { _, new in new }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": properties, "required": required]]
    }

    static var definitions: [[String: Any]] {
        [
            tool("list_items",
                 "List items, newest-priority first. By default only open items (not done/dropped). Returns compact records; use get_item for full detail.",
                 [
                     "kind": strEnum(kinds, "Filter by kind."),
                     "status": strEnum(statuses + ["open", "closed", "any"], "Filter by status. 'open' (default) excludes done/dropped; 'closed' is done+dropped; 'any' is everything."),
                     "project_id": str("Filter by project id. Use 'none' for items without a project."),
                     "area": strEnum(ProjectType.allCases.map(\.rawValue), "Filter by area: the item's project type, or for items without a project, the area its kind belongs to (research kinds, personal, misc)."),
                     "query": str("Case-insensitive text search over title, notes, and tags."),
                     "today": ["type": "boolean", "description": "Only items in the Today list (flagged, due, or in progress)."],
                     "limit": ["type": "integer", "description": "Max results (default 50, max 200)."],
                 ]),
            tool("get_item",
                 "Get one item with all fields, its checklist, and its recent progress log.",
                 ["id": str("Item id.")], required: ["id"]),
            tool("create_item",
                 "Create an item. Check list_items first to avoid duplicates. Pick the kind carefully: implementation is coding, running/evaluating is experiment.",
                 merge(itemFields, ["checklist": merge(strArray, ["description": "Initial checklist steps."])]),
                 required: ["title", "kind"]),
            tool("update_item",
                 "Update fields of an item. Only fields you pass change. Use `log` to record what happened, and `append_notes` to add to notes without replacing them.",
                 merge(itemFields, [
                     "id": str("Item id."),
                     "append_notes": str("Text appended to the end of the existing notes."),
                     "log": str("A progress-log entry describing what changed or happened."),
                 ]),
                 required: ["id"]),
            tool("update_checklist",
                 "Add, check, uncheck, or remove checklist steps of an item. Steps are matched by id or exact title (case-insensitive).",
                 [
                     "item_id": str("Item id."),
                     "add": merge(strArray, ["description": "New step titles to append."]),
                     "check": merge(strArray, ["description": "Steps to mark done."]),
                     "uncheck": merge(strArray, ["description": "Steps to mark not done."]),
                     "remove": merge(strArray, ["description": "Steps to delete."]),
                 ],
                 required: ["item_id"]),
            tool("add_log",
                 "Append a progress note to an item's log without changing its fields.",
                 ["item_id": str("Item id."), "text": str("The note.")],
                 required: ["item_id", "text"]),
            tool("list_projects",
                 "List projects with their type. Research projects report per-kind progress; personal and misc projects report open, recently done, and overdue counts.",
                 [
                     "type": strEnum(ProjectType.allCases.map(\.rawValue), "Only projects of this type."),
                     "include_archived": ["type": "boolean", "description": "Include archived projects (default false)."],
                 ]),
            tool("create_project",
                 "Create a project. Check list_projects first to avoid duplicates. type: research = a paper, research thread, or system; personal = an area or effort in the user's life (health, finances, a trip, a move); misc = a group for other tasks (errands, admin, reviewing duties).",
                 [
                     "name": str("Project name."),
                     "type": strEnum(ProjectType.allCases.map(\.rawValue), "Project type (default research)."),
                     "summary": str("Goal, venue, or scope."),
                     "deadline": str("YYYY-MM-DD."),
                     "color": strEnum(Project.palette, "Display color."),
                     "symbol": strEnum(Project.symbols, "SF Symbol icon."),
                 ],
                 required: ["name"]),
            tool("update_project",
                 "Update a project's name, type, summary, status, or deadline. Changing the type doesn't change its items' kinds.",
                 [
                     "id": str("Project id."),
                     "name": str("New name."),
                     "type": strEnum(ProjectType.allCases.map(\.rawValue), "Project type."),
                     "summary": str("New summary."),
                     "status": strEnum(ProjectStatus.allCases.map(\.rawValue), "Project status."),
                     "deadline": str("YYYY-MM-DD, or empty string to clear."),
                 ],
                 required: ["id"]),
            tool("review_summary",
                 "Progress snapshot for the last N days: completed and created items, experiments by phase with outcomes, active coding work, blocked/overdue/stale items, and the activity log.",
                 ["days": ["type": "integer", "description": "Window in days (default 7, max 90)."]]),
        ]
    }

    // MARK: Dispatch

    func run(name: String, input: [String: Any]) -> ToolOutcome {
        let args = Args(raw: input)
        do {
            switch name {
            case "list_items": return try listItems(args)
            case "get_item": return try getItem(args)
            case "create_item": return try createItem(args)
            case "update_item": return try updateItem(args)
            case "update_checklist": return try updateChecklist(args)
            case "add_log": return try addLog(args)
            case "list_projects": return try listProjects(args)
            case "create_project": return try createProject(args)
            case "update_project": return try updateProject(args)
            case "review_summary": return try reviewSummary(args)
            default: throw ToolInputError(message: "Unknown tool \(name)")
            }
        } catch let error as ToolInputError {
            return ToolOutcome(result: "Error: \(error.message)", summary: "\(name) failed: \(error.message)", isError: true)
        } catch {
            return ToolOutcome(result: "Error: \(error.localizedDescription)", summary: "\(name) failed", isError: true)
        }
    }

    // MARK: Items

    private func listItems(_ a: Args) throws -> ToolOutcome {
        let kind = try a.enumValue("kind", ItemKind.self)
        let statusFilter = try a.string("status") ?? "open"
        let projectID = try a.string("project_id")
        let area = try a.enumValue("area", ProjectType.self)
        let query = try a.string("query")?.lowercased()
        let todayOnly = try a.bool("today") ?? false
        let limit = min(max(try a.int("limit") ?? 50, 1), 200)

        var list = todayOnly ? store.items(for: .today) : store.items.sorted(by: Store.sortKey)
        if let kind { list = list.filter { $0.kind == kind } }
        if let area { list = list.filter { store.type(of: $0) == area } }
        switch statusFilter {
        case "open": list = list.filter { $0.status.isOpen }
        case "closed": list = list.filter { !$0.status.isOpen }
        case "any": break
        default:
            guard let s = ItemStatus(rawValue: statusFilter) else { throw ToolInputError(message: "Invalid status \(statusFilter)") }
            list = list.filter { $0.status == s }
        }
        if let projectID {
            list = projectID == "none" ? list.filter { $0.projectID == nil } : list.filter { $0.projectID == projectID }
        }
        if let query, !query.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(query) || $0.notes.lowercased().contains(query)
                    || $0.tags.contains { $0.lowercased().contains(query) }
            }
        }
        let total = list.count
        let payload: [String: Any] = ["total": total, "items": list.prefix(limit).map { compact($0) }]
        return ToolOutcome(result: json(payload), summary: "Looked up \(total) item\(total == 1 ? "" : "s")", isError: false)
    }

    private func getItem(_ a: Args) throws -> ToolOutcome {
        let item = try requireItem(a.requiredString("id"))
        var full = detail(item)
        full["log"] = store.logs(forItem: item.id, limit: 25).map { log -> [String: Any] in
            ["at": iso(log.createdAt), "author": log.author.rawValue, "kind": log.kind, "text": log.text]
        }
        return ToolOutcome(result: json(full), summary: "Read “\(item.title)”", isError: false)
    }

    private func createItem(_ a: Args) throws -> ToolOutcome {
        let title = try a.requiredString("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ToolInputError(message: "title must not be empty") }
        var draft = Item(id: "", title: title)
        try apply(a, to: &draft)
        let checklist = try a.stringArray("checklist") ?? []
        let created = store.createItem(draft, checklist: checklist, author: .agent)
        return ToolOutcome(result: json(["created": compact(created)]),
                           summary: "Created \(created.kind.label.lowercased()) “\(created.title)”", isError: false)
    }

    private func updateItem(_ a: Args) throws -> ToolOutcome {
        var item = try requireItem(a.requiredString("id"))
        if let title = try a.string("title") {
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolInputError(message: "title must not be empty") }
            item.title = title
        }
        try apply(a, to: &item)
        if let extra = try a.string("append_notes"), !extra.isEmpty {
            item.notes = item.notes.isEmpty ? extra : item.notes + "\n\n" + extra
        }
        store.updateItem(item, author: .agent)
        if let log = try a.string("log"), !log.isEmpty { store.addNote(log, itemID: item.id, author: .agent) }
        let updated = store.item(item.id) ?? item
        return ToolOutcome(result: json(["updated": compact(updated)]), summary: "Updated “\(updated.title)”", isError: false)
    }

    /// Applies optional fields shared by create and update.
    private func apply(_ a: Args, to item: inout Item) throws {
        if let v = try a.enumValue("kind", ItemKind.self) { item.kind = v }
        if let v = try a.enumValue("status", ItemStatus.self) { item.status = v }
        if let v = try a.string("priority") {
            guard let p = Priority.allCases.first(where: { $0.name == v }) else { throw ToolInputError(message: "Invalid priority \(v)") }
            item.priority = p
        }
        if let v = try a.string("project_id") {
            if v.isEmpty || v == "none" {
                item.projectID = nil
            } else {
                guard store.project(v) != nil else { throw ToolInputError(message: "No project with id \(v). Call list_projects.") }
                item.projectID = v
            }
        }
        if let v = try a.string("notes") { item.notes = v }
        if case .set(let d) = try a.date("due_date") { item.dueDate = d } else if case .clear = try a.date("due_date") { item.dueDate = nil }
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
        if let raw = a.raw["metrics"] {
            guard let list = raw as? [[String: Any]] else { throw ToolInputError(message: "metrics must be an array of {name, value}") }
            item.metrics = try list.map { m in
                guard let name = m["name"] as? String else { throw ToolInputError(message: "each metric needs a string name") }
                let value: String
                if let s = m["value"] as? String { value = s } else if let n = m["value"] as? NSNumber { value = n.stringValue } else {
                    throw ToolInputError(message: "metric \(name) needs a value")
                }
                return Metric(name: name, value: value)
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
    }

    private func updateChecklist(_ a: Args) throws -> ToolOutcome {
        let item = try requireItem(a.requiredString("item_id"))
        var changes: [String] = []

        func find(_ key: String) throws -> ChecklistEntry {
            let current = store.item(item.id)?.checklist ?? []
            if let e = current.first(where: { $0.id == key || $0.title.lowercased() == key.lowercased() }) { return e }
            throw ToolInputError(message: "No checklist step matching “\(key)” on item \(item.id)")
        }

        for title in try a.stringArray("add") ?? [] where !title.isEmpty {
            store.addChecklistEntry(to: item.id, title: title)
            changes.append("added \(title)")
        }
        for key in try a.stringArray("check") ?? [] {
            var e = try find(key); e.done = true
            store.updateChecklistEntry(e, author: .agent)
            changes.append("checked \(e.title)")
        }
        for key in try a.stringArray("uncheck") ?? [] {
            var e = try find(key); e.done = false
            store.updateChecklistEntry(e, author: .agent)
            changes.append("unchecked \(e.title)")
        }
        for key in try a.stringArray("remove") ?? [] {
            let e = try find(key)
            store.removeChecklistEntry(e)
            changes.append("removed \(e.title)")
        }
        let updated = store.item(item.id) ?? item
        let p = updated.checklistProgress
        return ToolOutcome(
            result: json(["item_id": item.id, "changes": changes,
                          "checklist": updated.checklist.map { ["id": $0.id, "title": $0.title, "done": $0.done] }]),
            summary: "Checklist of “\(updated.title)”: \(p.done)/\(p.total) done", isError: false)
    }

    private func addLog(_ a: Args) throws -> ToolOutcome {
        let item = try requireItem(a.requiredString("item_id"))
        let text = try a.requiredString("text")
        guard !text.isEmpty else { throw ToolInputError(message: "text must not be empty") }
        store.addNote(text, itemID: item.id, author: .agent)
        return ToolOutcome(result: "Logged.", summary: "Logged progress on “\(item.title)”", isError: false)
    }

    // MARK: Projects

    private func listProjects(_ a: Args) throws -> ToolOutcome {
        let includeArchived = try a.bool("include_archived") ?? false
        let type = try a.enumValue("type", ProjectType.self)
        let list = store.projects.filter { (includeArchived || $0.status != .archived) && (type == nil || $0.type == type) }
        let payload = list.map { p -> [String: Any] in
            var d: [String: Any] = ["id": p.id, "name": p.name, "type": p.type.rawValue, "status": p.status.rawValue]
            if p.type == .research {
                var progress: [String: String] = [:]
                for kind in ItemKind.allCases {
                    let pr = store.progress(kind: kind, projectID: p.id)
                    if pr.total > 0 { progress[kind.rawValue] = "\(pr.done)/\(pr.total) done" }
                }
                d["progress"] = progress
            } else {
                let pulse = store.pulse(projectID: p.id)
                var counts: [String: Any] = ["open": pulse.open, "done_last_7_days": pulse.doneThisWeek, "overdue": pulse.overdue]
                if let next = pulse.nextDue, let due = next.dueDate { counts["next_due"] = ["id": next.id, "title": next.title, "due": day(due)] }
                d["activity"] = counts
            }
            if !p.summary.isEmpty { d["summary"] = p.summary }
            if let deadline = p.deadline { d["deadline"] = day(deadline) }
            return d
        }
        return ToolOutcome(result: json(["projects": payload]), summary: "Looked up \(list.count) project\(list.count == 1 ? "" : "s")", isError: false)
    }

    private func createProject(_ a: Args) throws -> ToolOutcome {
        let name = try a.requiredString("name").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ToolInputError(message: "name must not be empty") }
        let type = try a.enumValue("type", ProjectType.self) ?? .research
        var draft = Project(id: "", name: name, type: type)
        draft.summary = try a.string("summary") ?? ""
        if case .set(let d) = try a.date("deadline") { draft.deadline = d }
        if let c = try a.string("color") { draft.color = Project.palette.contains(c) ? c : type.defaultColor }
        if let s = try a.string("symbol") { draft.symbol = Project.symbols.contains(s) ? s : type.defaultSymbol }
        let p = store.createProject(draft, author: .agent)
        return ToolOutcome(result: json(["created": ["id": p.id, "name": p.name, "type": p.type.rawValue]]),
                           summary: "Created \(p.type.label.lowercased()) project “\(p.name)”", isError: false)
    }

    private func updateProject(_ a: Args) throws -> ToolOutcome {
        let id = try a.requiredString("id")
        guard var p = store.project(id) else { throw ToolInputError(message: "No project with id \(id)") }
        if let v = try a.string("name"), !v.isEmpty { p.name = v }
        if let v = try a.string("summary") { p.summary = v }
        if let v = try a.enumValue("type", ProjectType.self) { p.type = v }
        if let v = try a.enumValue("status", ProjectStatus.self) { p.status = v }
        switch try a.date("deadline") {
        case .set(let d): p.deadline = d
        case .clear: p.deadline = nil
        case .absent: break
        }
        store.updateProject(p, author: .agent)
        return ToolOutcome(result: json(["updated": ["id": p.id, "name": p.name, "type": p.type.rawValue, "status": p.status.rawValue]]),
                           summary: "Updated project “\(p.name)”", isError: false)
    }

    // MARK: Review

    private func reviewSummary(_ a: Args) throws -> ToolOutcome {
        let days = min(max(try a.int("days") ?? 7, 1), 90)
        let s = store.review(days: days)
        let payload: [String: Any] = [
            "window": ["days": days, "since": day(s.since), "today": day(Date())],
            "completed": s.completed.map(compact),
            "created_count": s.created.count,
            "experiments": [
                "running": s.runningExperiments.map(detailBrief),
                "analyzing": s.analyzingExperiments.map(detailBrief),
                "concluded_in_window": s.concludedExperiments.map(detailBrief),
                "planned": s.plannedExperiments.map(compact),
            ],
            "coding_active": s.activeCoding.map(compact),
            "blocked": s.blocked.map(compact),
            "overdue": s.overdue.map(compact),
            "stale_no_update_\(ReviewSummary.staleAfterDays)d": s.stale.map(compact),
            "activity": s.logs.prefix(120).map { log -> [String: Any] in
                ["at": iso(log.createdAt), "item": store.item(log.itemID)?.title ?? store.project(log.projectID)?.name ?? "",
                 "author": log.author.rawValue, "text": log.text]
            },
        ]
        return ToolOutcome(result: json(payload), summary: "Gathered \(days)-day review", isError: false)
    }

    // MARK: Serialization

    private func requireItem(_ id: String) throws -> Item {
        guard let item = store.item(id) else { throw ToolInputError(message: "No item with id \(id). Use list_items to find ids.") }
        return item
    }

    private func compact(_ i: Item) -> [String: Any] {
        var d: [String: Any] = ["id": i.id, "title": i.title, "kind": i.kind.rawValue, "status": i.status.rawValue,
                                "status_label": i.statusLabel, "updated": day(i.updatedAt)]
        if i.priority != .none { d["priority"] = i.priority.name }
        if let p = store.project(i.projectID) { d["project"] = ["id": p.id, "name": p.name, "type": p.type.rawValue] }
        if let due = i.dueDate { d["due"] = day(due) }
        if i.flaggedToday { d["today"] = true }
        if !i.tags.isEmpty { d["tags"] = i.tags }
        let pr = i.checklistProgress
        if pr.total > 0 { d["checklist"] = "\(pr.done)/\(pr.total)" }
        if i.kind == .experiment, i.outcome != .pending { d["outcome"] = i.outcome.rawValue }
        if let done = i.completedAt { d["closed"] = day(done) }
        if !i.notes.isEmpty { d["notes_preview"] = String(i.notes.prefix(160)) }
        return d
    }

    private func detailBrief(_ i: Item) -> [String: Any] {
        var d = compact(i)
        if !i.hypothesis.isEmpty { d["hypothesis"] = i.hypothesis }
        if !i.metrics.isEmpty { d["metrics"] = i.metrics.map { ["name": $0.name, "value": $0.value] } }
        if !i.conclusion.isEmpty { d["conclusion"] = i.conclusion }
        if let s = i.runStartedAt { d["run_started_at"] = iso(s) }
        if let e = i.runEndedAt { d["run_ended_at"] = iso(e) }
        return d
    }

    private func detail(_ i: Item) -> [String: Any] {
        var d = compact(i)
        d.removeValue(forKey: "notes_preview")
        d["notes"] = i.notes
        d["created"] = iso(i.createdAt)
        d["checklist"] = i.checklist.map { ["id": $0.id, "title": $0.title, "done": $0.done] }
        switch i.kind {
        case .coding:
            d["repo"] = i.repo; d["branch"] = i.branch; d["link"] = i.link
        case .experiment:
            d["hypothesis"] = i.hypothesis; d["setup"] = i.setup; d["compute"] = i.compute
            d["results"] = i.results; d["conclusion"] = i.conclusion; d["outcome"] = i.outcome.rawValue
            d["metrics"] = i.metrics.map { ["name": $0.name, "value": $0.value] }
            d["run_started_at"] = i.runStartedAt.map(iso) ?? NSNull()
            d["run_ended_at"] = i.runEndedAt.map(iso) ?? NSNull()
        default:
            break
        }
        return d
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private func iso(_ d: Date) -> String { d.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted)) }
private func day(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

// MARK: - Input validation

enum DateArg {
    case absent, clear, set(Date)
}

struct Args {
    let raw: [String: Any]

    private func present(_ key: String) -> Any? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        return v
    }

    func string(_ key: String) throws -> String? {
        guard let v = present(key) else { return nil }
        guard let s = v as? String else { throw ToolInputError(message: "\(key) must be a string") }
        return s
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key) else { throw ToolInputError(message: "\(key) is required") }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = present(key) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ToolInputError(message: "\(key) must be a boolean") }
        return n.boolValue
    }

    func int(_ key: String) throws -> Int? {
        guard let v = present(key) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw ToolInputError(message: "\(key) must be an integer") }
        return n.intValue
    }

    func stringArray(_ key: String) throws -> [String]? {
        guard let v = present(key) else { return nil }
        guard let a = v as? [String] else { throw ToolInputError(message: "\(key) must be an array of strings") }
        return a
    }

    func enumValue<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == String {
        guard let s = try string(key) else { return nil }
        guard let e = E(rawValue: s) else { throw ToolInputError(message: "Invalid \(key) “\(s)”") }
        return e
    }

    func date(_ key: String) throws -> DateArg {
        guard let s = try string(key)?.trimmingCharacters(in: .whitespaces) else { return .absent }
        if s.isEmpty { return .clear }
        if s.lowercased() == "now" { return .set(Date()) }
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        if let d = dayFormat.date(from: s) { return .set(d) }
        for f in [ISO8601DateFormatter.Options.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = f
            if let d = iso.date(from: s) { return .set(d) }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            dayFormat.dateFormat = format
            if let d = dayFormat.date(from: s) { return .set(d) }
        }
        throw ToolInputError(message: "\(key) must be YYYY-MM-DD or ISO 8601, got “\(s)”")
    }
}
