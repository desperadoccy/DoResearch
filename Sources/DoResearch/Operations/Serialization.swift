import Foundation

/// Canonical JSON for items, projects, and log entries, returned to the assistant and to API clients alike.
/// Keys are always present (null when empty), so clients can rely on the shape. Each builder has a schema beside it.
@MainActor
struct Serializer {
    let store: Store

    // MARK: Items

    /// Compact record used in lists and the review summary.
    func summary(_ i: Item) -> [String: Any] {
        let p = i.checklistProgress
        return [
            "id": i.id, "title": i.title, "kind": i.kind.rawValue, "status": i.status.rawValue, "status_label": i.statusLabel,
            "priority": i.priority.name, "project_id": i.projectID ?? NSNull(), "project": projectRef(i.projectID),
            "due_date": i.dueDate.map(Wire.day) ?? NSNull(), "today": i.flaggedToday, "tags": i.tags,
            "checklist_done": p.done, "checklist_total": p.total,
            "tracks_progress": i.tracksProgress, "progress_current": i.progressCurrent,
            "progress_target": i.progressTarget ?? NSNull(), "progress_unit": i.progressUnit,
            "progress_label": i.tracksProgress ? i.progressLabel : NSNull(),
            "outcome": i.outcome.rawValue, "chat_ids": i.chatIDs, "revision": i.revision,
            "updated_at": Wire.time(i.updatedAt), "completed_at": i.completedAt.map(Wire.time) ?? NSNull(),
            "notes_preview": String(i.notes.prefix(160)),
        ]
    }

    /// Every field of an item, its checklist as records, and optionally its most recent log entries.
    func detail(_ i: Item, logLimit: Int = 0) -> [String: Any] {
        var d = summary(i)
        d.removeValue(forKey: "notes_preview")
        d["notes"] = i.notes
        d["repo"] = i.repo; d["branch"] = i.branch; d["link"] = i.link
        d["hypothesis"] = i.hypothesis; d["setup"] = i.setup; d["compute"] = i.compute
        d["results"] = i.results; d["conclusion"] = i.conclusion
        d["metrics"] = i.metrics.map { ["name": $0.name, "value": $0.value] }
        d["run_started_at"] = i.runStartedAt.map(Wire.time) ?? NSNull()
        d["run_ended_at"] = i.runEndedAt.map(Wire.time) ?? NSNull()
        d["checklist"] = i.checklist.map(checklistEntry)
        d["created_at"] = Wire.time(i.createdAt)
        if logLimit > 0 { d["progress_log"] = store.logs(forItem: i.id, limit: logLimit).map(logEntry) }
        return d
    }

    func checklistEntry(_ e: ChecklistEntry) -> [String: Any] {
        ["id": e.id, "title": e.title, "done": e.done, "position": e.position]
    }

    func logEntry(_ l: LogEntry) -> [String: Any] {
        ["id": l.id, "created_at": Wire.time(l.createdAt), "kind": l.kind, "text": l.text, "author": l.author.rawValue,
         "item_id": l.itemID ?? NSNull(), "project_id": l.projectID ?? NSNull(),
         "source_chat_id": l.sourceChatID ?? NSNull(), "idempotency_key": l.idempotencyKey ?? NSNull()]
    }

    private func projectRef(_ id: String?) -> Any {
        store.project(id).map { ["id": $0.id, "name": $0.name, "type": $0.type.rawValue] } ?? NSNull()
    }

    /// Experiment detail used by the review summary.
    func experimentBrief(_ i: Item) -> [String: Any] {
        var d = summary(i)
        d["hypothesis"] = i.hypothesis
        d["metrics"] = i.metrics.map { ["name": $0.name, "value": $0.value] }
        d["conclusion"] = i.conclusion
        d["run_started_at"] = i.runStartedAt.map(Wire.time) ?? NSNull()
        d["run_ended_at"] = i.runEndedAt.map(Wire.time) ?? NSNull()
        return d
    }

    // MARK: Projects

    func project(_ p: Project) -> [String: Any] {
        var progress: [String: Any] = [:]
        for kind in ItemKind.allCases {
            let pr = store.progress(kind: kind, projectID: p.id)
            if pr.total > 0 { progress[kind.rawValue] = ["done": pr.done, "total": pr.total] }
        }
        let pulse = store.pulse(projectID: p.id)
        var next: Any = NSNull()
        if let due = pulse.nextDue {
            next = ["id": due.id, "title": due.title, "due_date": due.dueDate.map(Wire.day) as Any? ?? NSNull()]
        }
        return [
            "id": p.id, "name": p.name, "type": p.type.rawValue, "status": p.status.rawValue, "summary": p.summary,
            "deadline": p.deadline.map(Wire.day) ?? NSNull(), "color": p.color, "symbol": p.symbol, "revision": p.revision,
            "created_at": Wire.time(p.createdAt), "updated_at": Wire.time(p.updatedAt),
            "progress": progress,
            "activity": ["open": pulse.open, "done_last_7_days": pulse.doneThisWeek, "overdue": pulse.overdue, "next_due": next],
        ]
    }
}

// MARK: - Schemas

/// JSON Schema builders for operation inputs and outputs.
enum Schema {
    static func string(_ description: String? = nil) -> [String: Any] { described(["type": "string"], description) }
    static func integer(_ description: String? = nil) -> [String: Any] { described(["type": "integer"], description) }
    static func boolean(_ description: String? = nil) -> [String: Any] { described(["type": "boolean"], description) }
    static func choice(_ values: [String], _ description: String? = nil) -> [String: Any] {
        described(["type": "string", "enum": values], description)
    }
    static func array(_ items: [String: Any], _ description: String? = nil) -> [String: Any] {
        described(["type": "array", "items": items], description)
    }
    static func nullable(_ schema: [String: Any]) -> [String: Any] { ["anyOf": [schema, ["type": "null"]]] }
    static func object(_ properties: [String: Any], required: [String]? = nil, closed: Bool = true) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties, "required": required ?? properties.keys.sorted()]
        if closed { o["additionalProperties"] = false }
        return o
    }

    private static func described(_ s: [String: Any], _ description: String?) -> [String: Any] {
        guard let description else { return s }
        return s.merging(["description": description]) { _, new in new }
    }

    static let time = string("ISO 8601 timestamp with UTC offset.")
    static let day = string("Calendar day, YYYY-MM-DD.")

    static var checklistEntry: [String: Any] {
        object(["id": string("Stable id."), "title": string(), "done": boolean(), "position": integer("Order within the checklist.")])
    }

    static var logEntry: [String: Any] {
        object([
            "id": string(), "created_at": time,
            "kind": choice(["created", "status", "note", "update", "progress"]),
            "text": string(), "author": choice(["user", "agent", "api"]),
            "item_id": nullable(string()), "project_id": nullable(string()),
            "source_chat_id": nullable(string()), "idempotency_key": nullable(string()),
        ])
    }

    static var projectRef: [String: Any] {
        nullable(object(["id": string(), "name": string(), "type": choice(ProjectType.allCases.map(\.rawValue))]))
    }

    static var itemSummary: [String: Any] {
        object(summaryProperties)
    }

    private static var summaryProperties: [String: Any] {
        [
            "id": string(), "title": string(), "kind": choice(ItemKind.allCases.map(\.rawValue)),
            "status": choice(StatusName.values), "status_label": string("Status as the app shows it for this kind."),
            "priority": choice(Priority.allCases.map(\.name)), "project_id": nullable(string()), "project": projectRef,
            "due_date": nullable(day), "today": boolean("Flagged for the Today list."), "tags": array(string()),
            "checklist_done": integer(), "checklist_total": integer(),
            "tracks_progress": boolean("Whether a quantitative target is set."),
            "progress_current": integer("Current count; 0 or more, may exceed the target."),
            "progress_target": nullable(integer("Positive target.")), "progress_unit": string(),
            "progress_label": nullable(string("Display label, e.g. “4/10 runs”.")),
            "outcome": choice(ExperimentOutcome.allCases.map(\.rawValue)), "chat_ids": array(string()),
            "revision": integer("Increases on every saved change."), "updated_at": time, "completed_at": nullable(time),
            "notes_preview": string("First 160 characters of the notes."),
        ]
    }

    static var item: [String: Any] {
        var props = summaryProperties
        props.removeValue(forKey: "notes_preview")
        props.merge([
            "notes": string(), "repo": string(), "branch": string(), "link": string(),
            "hypothesis": string(), "setup": string(), "compute": string(), "results": string(), "conclusion": string(),
            "metrics": array(object(["name": string(), "value": string()])),
            "run_started_at": nullable(time), "run_ended_at": nullable(time),
            "checklist": array(checklistEntry), "created_at": time,
            "progress_log": array(logEntry, "Most recent first. Present when requested (get_item) and after writes."),
        ]) { _, new in new }
        var required = props.keys.sorted()
        required.removeAll { $0 == "progress_log" }
        return object(props, required: required)
    }

    static var project: [String: Any] {
        let counts = object(["done": integer(), "total": integer()])
        return object([
            "id": string(), "name": string(), "type": choice(ProjectType.allCases.map(\.rawValue)),
            "status": choice(ProjectStatus.allCases.map(\.rawValue)), "summary": string(), "deadline": nullable(day),
            "color": choice(Project.palette), "symbol": string(), "revision": integer(), "created_at": time, "updated_at": time,
            "progress": ["type": "object", "description": "Per item kind: done and total items (dropped excluded).",
                         "additionalProperties": counts],
            "activity": object(["open": integer(), "done_last_7_days": integer(), "overdue": integer(),
                                "next_due": nullable(object(["id": string(), "title": string(), "due_date": nullable(day)]))]),
        ])
    }

    static var error: [String: Any] {
        object(["error": object(["code": string("Stable error code."), "message": string()], required: ["code", "message"], closed: false)])
    }
}
