import Foundation

/// One operation of the shared contract. The built-in assistant and the local HTTP API both call operations from
/// `OperationRegistry` through `OperationService`, so a new operation or field reaches both by being added here.
struct Operation {
    /// The existing object `expected_revision` is checked against: the argument naming an item or a project.
    enum RevisionTarget {
        case item(String)
        case project(String)
    }

    let name: String
    let description: String
    /// False for read-only operations, which ignore idempotency keys.
    let mutates: Bool
    let revisionTarget: RevisionTarget?
    /// JSON Schema of the arguments object.
    let input: [String: Any]
    /// JSON Schema of `result` in the response envelope.
    let output: [String: Any]
    let run: @MainActor (OperationService, Args, Author) throws -> OperationOutput

    var argumentNames: [String] { (input["properties"] as? [String: Any])?.keys.sorted() ?? [] }

    /// The shape model providers expect for tool definitions.
    var toolDefinition: [String: Any] { ["name": name, "description": description, "input_schema": input] }

    var discovery: [String: Any] {
        var revision: Any = NSNull()
        switch revisionTarget {
        case .item(let arg): revision = ["object": "item", "argument": arg]
        case .project(let arg): revision = ["object": "project", "argument": arg]
        case nil: break
        }
        return ["name": name, "description": description, "mutates": mutates, "expected_revision": revision,
                "input_schema": input, "output_schema": output]
    }
}

struct OperationOutput {
    var result: [String: Any]
    /// One line for the assistant panel.
    var summary: String
    /// Objects written, reported with their revision after the write.
    var affected: [(type: String, id: String)] = []
}

@MainActor
enum OperationRegistry {
    static func named(_ name: String) -> Operation? { all.first { $0.name == name } }

    static let all: [Operation] = [
        Operation(
            name: "list_items",
            description: "List items. By default only open items (not done/dropped), highest priority first. Returns compact records; use get_item for full detail.",
            mutates: false, revisionTarget: nil,
            input: Schema.object([
                "kind": Schema.choice(kinds, "Filter by kind."),
                "status": Schema.choice(StatusName.values + ["open", "closed", "any"], "Filter by status. 'open' (default) excludes done/dropped; 'closed' is done+dropped; 'any' is everything. Aliases such as Running are accepted."),
                "project_id": Schema.string("Filter by project id. Use 'none' for items without a project."),
                "area": Schema.choice(ProjectType.allCases.map(\.rawValue), "Filter by area: the item's project type, or for items without a project, the area its kind belongs to (research kinds, personal, misc)."),
                "query": Schema.string("Case-insensitive text search over title, notes, and tags."),
                "title": Schema.string("Case-insensitive search over titles only."),
                "chat_id": Schema.string("Only items linked to this external chat id."),
                "today": Schema.boolean("true: only items in the Today list (flagged, due, or in progress)."),
                "sort": Schema.choice(["priority", "updated", "manual"], "priority (default): priority, then due date, then newest. updated: most recently changed first. manual: the app's manual order."),
                "limit": Schema.integer("Max results (default 50, max 500)."),
            ], required: []),
            output: Schema.object(["total": Schema.integer("Matches before the limit."), "items": Schema.array(Schema.itemSummary)]),
            run: { service, args, _ in try service.listItems(args) }),
        Operation(
            name: "get_item",
            description: "Get one item with all fields, its checklist, quantitative progress, and its recent progress log.",
            mutates: false, revisionTarget: nil,
            input: Schema.object([
                "id": Schema.string("Item id."),
                "log_limit": Schema.integer("Log entries to include, newest first (default 25, max 500)."),
            ], required: ["id"]),
            output: Schema.object(["item": Schema.item]),
            run: { service, args, _ in try service.getItem(args) }),
        Operation(
            name: "create_item",
            description: "Create an item. Check list_items first to avoid duplicates. Pick the kind carefully: implementation is coding, running/evaluating is experiment.",
            mutates: true, revisionTarget: nil,
            input: Schema.object(itemFields.merging([
                "checklist": Schema.array(Schema.string(), "Initial checklist steps, in order."),
            ]) { _, new in new }, required: ["title", "kind"]),
            output: Schema.object(["item": Schema.item]),
            run: { try $0.createItem($1, $2) }),
        Operation(
            name: "update_item",
            description: "Update fields of an item. Only fields you pass change. Use `log` to record what happened, and `append_notes` to add to notes without replacing them.",
            mutates: true, revisionTarget: .item("id"),
            input: Schema.object(itemFields.merging([
                "id": Schema.string("Item id."),
                "append_notes": Schema.string("Text appended to the end of the existing notes."),
                "log": Schema.string("A progress-log entry describing what changed or happened."),
            ]) { _, new in new }, required: ["id"]),
            output: Schema.object(["item": Schema.item, "changed": Schema.array(Schema.string(), "Item fields whose value changed.")]),
            run: { try $0.updateItem($1, $2) }),
        Operation(
            name: "update_checklist",
            description: "Add, check, uncheck, or remove checklist steps of an item, all or nothing. Steps are matched by id, or by exact title (case-insensitive) when the title is unique. New steps are appended in order.",
            mutates: true, revisionTarget: .item("item_id"),
            input: Schema.object([
                "item_id": Schema.string("Item id."),
                "add": Schema.array(Schema.string(), "New step titles to append."),
                "check": Schema.array(Schema.string(), "Steps to mark done (ids or titles)."),
                "uncheck": Schema.array(Schema.string(), "Steps to mark not done (ids or titles)."),
                "remove": Schema.array(Schema.string(), "Steps to delete (ids or titles)."),
            ], required: ["item_id"]),
            output: Schema.object([
                "item_id": Schema.string(), "revision": Schema.integer(), "changed": Schema.boolean(),
                "checklist": Schema.array(Schema.checklistEntry, "The whole checklist after the change."),
                "added": Schema.array(Schema.checklistEntry, "The new steps, with their ids."),
            ]),
            run: { try $0.updateChecklist($1, $2) }),
        Operation(
            name: "add_log",
            description: "Append a note to an item's progress log without changing its fields or its progress count.",
            mutates: true, revisionTarget: .item("item_id"),
            input: Schema.object(["item_id": Schema.string("Item id."), "text": Schema.string("The note.")]),
            output: Schema.object(["item_id": Schema.string(), "revision": Schema.integer(), "log_entry": Schema.logEntry]),
            run: { try $0.addLog($1, $2) }),
        Operation(
            name: "list_projects",
            description: "List projects with their type, summary, per-kind progress, and activity (open, recently done, overdue, next due).",
            mutates: false, revisionTarget: nil,
            input: Schema.object([
                "type": Schema.choice(ProjectType.allCases.map(\.rawValue), "Only projects of this type."),
                "include_archived": Schema.boolean("Include archived projects (default false)."),
            ], required: []),
            output: Schema.object(["projects": Schema.array(Schema.project)]),
            run: { service, args, _ in try service.listProjects(args) }),
        Operation(
            name: "create_project",
            description: "Create a project. Names are unique among non-archived projects. type: research = a paper, research thread, or system; personal = an area or effort in the user's life (health, finances, a trip, a move); misc = a group for other tasks (errands, admin, reviewing duties).",
            mutates: true, revisionTarget: nil,
            input: Schema.object(projectFields, required: ["name"]),
            output: Schema.object(["project": Schema.project]),
            run: { try $0.createProject($1, $2) }),
        Operation(
            name: "update_project",
            description: "Update a project's name, type, summary, status, deadline, color, or icon. Changing the type doesn't change its items' kinds.",
            mutates: true, revisionTarget: .project("id"),
            input: Schema.object(projectFields.merging(["id": Schema.string("Project id.")]) { _, new in new }, required: ["id"]),
            output: Schema.object(["project": Schema.project, "changed": Schema.array(Schema.string(), "Project fields whose value changed.")]),
            run: { try $0.updateProject($1, $2) }),
        Operation(
            name: "review_summary",
            description: "Progress snapshot for the last N days: completed and created items, experiments by phase with outcomes, active coding work, blocked/overdue/stale items, and the activity log.",
            mutates: false, revisionTarget: nil,
            input: Schema.object(["days": Schema.integer("Window in days (default 7, max 90).")], required: []),
            output: reviewSchema,
            run: { service, args, _ in try service.reviewSummary(args) }),
    ]

    // MARK: Shared argument schemas

    static let kinds = ItemKind.allCases.map(\.rawValue)

    static var itemFields: [String: Any] {
        [
            "title": Schema.string("Short, specific title."),
            "kind": Schema.choice(kinds, "coding = implementation work; experiment = running/evaluating something; writing = paper/report text; reading = papers to read; task = other research work; personal; misc."),
            "status": Schema.choice(StatusName.values, "inbox = unsorted; todo; in_progress (experiment: running); waiting (experiment: analyzing, coding: in review); blocked; done; dropped (use instead of deleting). The experiment labels Inbox, Planned, Running, Analyzing, Blocked, Concluded, Dropped are accepted as aliases."),
            "priority": Schema.choice(Priority.allCases.map(\.name), "Priority."),
            "project_id": Schema.string("Project id, or empty string for no project."),
            "notes": Schema.string("Free-form notes (replaces existing notes)."),
            "due_date": Schema.string("YYYY-MM-DD, or empty string to clear."),
            "today": Schema.boolean("Show in the Today list."),
            "tags": Schema.array(Schema.string(), "Replaces existing tags."),
            "repo": Schema.string("Coding: repository path or URL."),
            "branch": Schema.string("Coding: git branch."),
            "link": Schema.string("Coding: PR or issue URL."),
            "hypothesis": Schema.string("Experiment: what is expected and why."),
            "setup": Schema.string("Experiment: config, command, dataset, seeds."),
            "compute": Schema.string("Experiment: hardware/cluster used."),
            "results": Schema.string("Experiment: observations and results (replaces existing)."),
            "conclusion": Schema.string("Experiment: what was learned / next steps."),
            "outcome": Schema.choice(ExperimentOutcome.allCases.map(\.rawValue), "Experiment: whether the hypothesis held."),
            "metrics": Schema.array(
                Schema.object(["name": Schema.string(), "value": ["type": ["string", "number"]]]),
                "Experiment: metric name/value pairs exactly as reported. Replaces existing metrics; numbers are stored as text."),
            "run_started_at": Schema.string("Experiment: ISO 8601 datetime, 'now', or empty string to clear."),
            "run_ended_at": Schema.string("Experiment: ISO 8601 datetime, 'now', or empty string to clear."),
            "progress_target": Schema.integer("Track measurable progress toward this count (e.g. 10 for 'read ten papers'). 0 stops tracking. Use this instead of creating one item per unit."),
            "progress_unit": Schema.string("Unit for the count, plural (e.g. 'papers', 'pages', 'runs')."),
            "progress": Schema.integer("Set the current count (0 or more). Needs a target, which may be set in the same request. Reaching the target marks the item done."),
            "progress_add": Schema.integer("Add to the current count (negative to subtract; the count stops at 0). Applied after `progress` when both are given. Prefer this when the user reports new progress, e.g. 'read two more'."),
            "chat_ids": Schema.array(Schema.string(), "Ids of external chats linked to this item. Replaces the list; duplicates are dropped."),
        ]
    }

    static var projectFields: [String: Any] {
        [
            "name": Schema.string("Project name."),
            "type": Schema.choice(ProjectType.allCases.map(\.rawValue), "Project type (default research)."),
            "summary": Schema.string("Goal, venue, or scope."),
            "status": Schema.choice(ProjectStatus.allCases.map(\.rawValue), "Project status (default active)."),
            "deadline": Schema.string("YYYY-MM-DD, or empty string to clear."),
            "color": Schema.choice(Project.palette, "Display color (default: the type's color)."),
            "symbol": Schema.choice(Project.symbols, "SF Symbol icon (default: the type's icon)."),
        ]
    }

    static var reviewSchema: [String: Any] {
        let items = Schema.array(Schema.itemSummary)
        let activity = Schema.object([
            "created_at": Schema.time, "item_id": Schema.nullable(Schema.string()), "project_id": Schema.nullable(Schema.string()),
            "title": Schema.string("Item title, or project name for project entries."), "kind": Schema.string(),
            "author": Schema.choice(["user", "agent", "api"]), "text": Schema.string(),
        ])
        return Schema.object([
            "window": Schema.object(["days": Schema.integer(), "since": Schema.day, "today": Schema.day]),
            "completed": items,
            "created_count": Schema.integer(),
            "experiments": Schema.object([
                "running": Schema.array(Schema.object([:], required: [], closed: false), "Item summaries plus hypothesis, metrics, conclusion, and run times."),
                "analyzing": Schema.array(Schema.object([:], required: [], closed: false)),
                "concluded_in_window": Schema.array(Schema.object([:], required: [], closed: false)),
                "planned": items,
            ]),
            "coding_active": items,
            "blocked": items,
            "overdue": items,
            "stale": items,
            "stale_after_days": Schema.integer(),
            "activity": Schema.array(activity, "Newest first, at most 120."),
        ])
    }

    /// The response envelope shared by every operation.
    static var envelopeSchema: [String: Any] {
        Schema.object([
            "operation": Schema.string(),
            "result": Schema.object([:], required: [], closed: false),
            "replayed": Schema.boolean("True when the idempotency key matched an earlier committed request; nothing was done again."),
            "affected": Schema.array(Schema.object([
                "type": Schema.choice(["item", "project"]), "id": Schema.string(), "revision": Schema.integer("Revision after the write."),
            ])),
        ])
    }
}
