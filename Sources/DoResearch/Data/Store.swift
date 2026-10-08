import Foundation
import Observation

/// Single source of truth for items, projects, and the activity log.
/// Both the UI and the agent mutate data only through this type, so every change is persisted and logged.
@Observable
@MainActor
final class Store {
    private(set) var items: [Item] = []
    private(set) var projects: [Project] = []
    /// Bumped on every activity-log write so views that query logs refresh.
    private(set) var logRevision = 0
    var lastError: String?

    private let db: Database

    init(url: URL = Database.defaultURL) {
        do {
            db = try Database(url: url)
        } catch {
            fatalError("Failed to open database: \(error.localizedDescription)")
        }
        reload()
        if db.didAddPositions {
            // Keep lists looking exactly as they did before manual ordering existed.
            let ordered = items.sorted(by: Self.sortKey)
            setPositions(Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, Double($0)) }))
        }
    }

    func reload() {
        do {
            projects = try db.query("SELECT * FROM projects ORDER BY created_at").map(Self.project(from:))
            let checklistRows = try db.query("SELECT * FROM checklist ORDER BY position, rowid")
            var byItem: [String: [ChecklistEntry]] = [:]
            for row in checklistRows {
                let e = Self.checklist(from: row)
                byItem[e.itemID, default: []].append(e)
            }
            items = try db.query("SELECT * FROM items").map { row in
                var item = Self.item(from: row)
                item.checklist = byItem[item.id] ?? []
                return item
            }
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("DoResearch store error: \(error.localizedDescription)")
    }

    // MARK: Lookup

    func item(_ id: String?) -> Item? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func project(_ id: String?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    var activeProjects: [Project] { projects.filter { $0.status == .active || $0.status == .paused } }

    // MARK: Items

    /// Inserts a new item at the top of the manual order. Checklist steps come from `checklist` if given,
    /// otherwise from `draft.checklist` (keeping their done state, as when duplicating).
    @discardableResult
    func createItem(_ draft: Item, checklist: [String] = [], author: Author = .user, logText: String? = nil) -> Item {
        var item = draft
        if item.id.isEmpty || self.item(item.id) != nil { item.id = uniqueItemID() }
        let now = Date()
        item.createdAt = now
        item.updatedAt = now
        item.position = (items.map(\.position).min() ?? 0) - 1
        if !item.status.isOpen, item.completedAt == nil { item.completedAt = now }
        if item.status.isOpen { item.completedAt = nil }
        if item.kind == .experiment, item.status == .inProgress, item.runStartedAt == nil { item.runStartedAt = now }
        let steps = checklist.isEmpty ? draft.checklist.map { ($0.title, $0.done) } : checklist.map { ($0, false) }
        item.checklist = []
        do {
            try db.transaction {
                try db.execute(
                    "INSERT INTO items (\(Self.itemColumns.joined(separator: ","))) VALUES (\(Self.placeholders(Self.itemColumns.count)))",
                    Self.itemParams(item)
                )
                for (i, step) in steps.enumerated() {
                    let entry = ChecklistEntry(id: ShortID.make(10), itemID: item.id, title: step.0, done: step.1, position: i)
                    try insertChecklist(entry)
                    item.checklist.append(entry)
                }
            }
            items.append(item)
            log(item: item.id, project: item.projectID, kind: "created",
                text: logText ?? "Created \(item.kind.label.lowercased()) “\(item.title)”", author: author)
        } catch {
            report(error)
        }
        return item
    }

    /// Persists `updated`. Status transitions are timestamped and logged; agent edits are always logged.
    func updateItem(_ updated: Item, author: Author = .user) {
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
        let old = items[index]
        var item = updated
        item.position = old.position // ordering changes only through reorder(), so stale copies can't undo a drag
        guard old != item else { return }
        item.updatedAt = Date()

        if old.kind != .experiment, item.kind == .experiment, item.status == .inProgress, item.runStartedAt == nil {
            item.runStartedAt = Date()
        }
        if old.status != item.status {
            let now = Date()
            item.completedAt = item.status.isOpen ? nil : (item.completedAt ?? now)
            if item.kind == .experiment {
                if item.status == .inProgress, item.runStartedAt == nil { item.runStartedAt = now }
                if old.status == .inProgress, item.runEndedAt == nil, [.waiting, .done, .dropped].contains(item.status) {
                    item.runEndedAt = now
                }
            }
        }

        do {
            let assignments = Self.itemColumns.dropFirst().map { "\($0) = ?" }.joined(separator: ", ")
            var params = Array(Self.itemParams(item).dropFirst())
            params.append(item.id)
            try db.execute("UPDATE items SET \(assignments) WHERE id = ?", params)
            items[index] = item

            if old.status != item.status {
                log(item: item.id, project: item.projectID, kind: "status",
                    text: "\(old.status.label(for: item.kind)) → \(item.status.label(for: item.kind))", author: author)
            }
            if author == .agent {
                let changed = Self.changedFields(old, item).filter { $0 != "status" }
                if !changed.isEmpty {
                    log(item: item.id, project: item.projectID, kind: "update",
                        text: "Updated \(changed.joined(separator: ", "))", author: author)
                }
            }
        } catch {
            report(error)
        }
    }

    func setStatus(_ status: ItemStatus, for id: String, author: Author = .user) {
        guard var item = item(id) else { return }
        item.status = status
        updateItem(item, author: author)
    }

    func deleteItem(_ id: String) {
        do {
            try db.execute("DELETE FROM items WHERE id = ?", [id])
            items.removeAll { $0.id == id }
            logRevision += 1
        } catch {
            report(error)
        }
    }

    private func uniqueItemID() -> String {
        var id = ShortID.make()
        while item(id) != nil { id = ShortID.make() }
        return id
    }

    // MARK: Ordering, moving, copying

    /// Writes positions without touching `updatedAt`: reordering isn't progress, and shouldn't hide stale work.
    func setPositions(_ positions: [String: Double]) {
        guard !positions.isEmpty else { return }
        do {
            try db.transaction {
                for (id, position) in positions {
                    try db.execute("UPDATE items SET position = ? WHERE id = ?", [position, id])
                }
            }
            for i in items.indices {
                if let p = positions[items[i].id] { items[i].position = p }
            }
        } catch {
            report(error)
        }
    }

    /// Moves `ids` (in this order) so they sit just before `anchorID` in `visible`, or at its end when nil.
    /// `visible` is the list as the user sees it; positions are global, so hidden items keep their relative order.
    func reorder(_ ids: [String], before anchorID: String?, within visible: [Item]) {
        let moving = Set(ids)
        let ids = ids.filter { item($0) != nil }
        guard !ids.isEmpty else { return }
        let current = visible.compactMap { item($0.id) }.filter { !moving.contains($0.id) }
        let others = items.filter { !moving.contains($0.id) }.map(\.position).sorted()
        let insertAt = anchorID.flatMap { a in current.firstIndex { $0.id == a } } ?? current.count
        let prev = insertAt > 0 ? current[insertAt - 1].position : nil
        let next = insertAt < current.count ? current[insertAt].position : nil
        let gap = Double(ids.count + 1)

        // Land directly after the visible predecessor (or before the visible successor) in the global order.
        var lo: Double, hi: Double
        if let prev {
            lo = prev
            hi = others.first { $0 > prev } ?? prev + gap
            if let next, next > prev, next < hi { hi = next }
        } else if let next {
            hi = next
            lo = others.last { $0 < next } ?? next - gap
        } else {
            hi = others.first ?? 0
            lo = hi - gap
        }
        let step = (hi - lo) / gap
        guard step > 1e-6 else {
            renumberPositions()
            reorder(ids, before: anchorID, within: visible)
            return
        }
        setPositions(Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, lo + step * Double($0 + 1)) }))
    }

    private func renumberPositions() {
        let ordered = items.sorted(by: Self.manualOrder)
        setPositions(Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, Double($0)) }))
    }

    /// Lands `incoming` in a list: existing items are moved (or duplicated when `copy`), items not in the store
    /// (pasted text, snapshots of deleted items) are created. Returns the ids of the items now in place.
    @discardableResult
    func place(_ incoming: [Item], copy: Bool, placement: Placement,
               before anchorID: String?, within visible: [Item]?) -> [String] {
        var placed: [String] = []
        for source in incoming {
            if !copy, var existing = item(source.id) {
                placement.apply(to: &existing)
                updateItem(existing)
                placed.append(existing.id)
            } else {
                let live = item(source.id)
                var draft = live ?? source
                draft.id = ""
                placement.apply(to: &draft)
                let created = createItem(draft, logText: live.map { "Copied from “\($0.title)”" })
                placed.append(created.id)
            }
        }
        if let visible { reorder(placed, before: anchorID, within: visible) }
        return placed
    }

    /// Copies each item and puts the copy right after its original.
    @discardableResult
    func duplicate(_ ids: [String]) -> [String] {
        var created: [String] = []
        for id in ids {
            guard let original = item(id) else { continue }
            var draft = original
            draft.id = ""
            let copy = createItem(draft, logText: "Duplicated from “\(original.title)”")
            let ordered = items.sorted(by: Self.manualOrder)
            let successor = ordered.firstIndex { $0.id == id }.flatMap { i in
                ordered[(i + 1)...].first { $0.id != copy.id }?.id
            }
            reorder([copy.id], before: successor, within: ordered)
            created.append(copy.id)
        }
        return created
    }

    // MARK: Checklist

    private func insertChecklist(_ e: ChecklistEntry) throws {
        try db.execute("INSERT INTO checklist (id, item_id, title, done, position) VALUES (?,?,?,?,?)",
                       [e.id, e.itemID, e.title, e.done, e.position])
    }

    @discardableResult
    func addChecklistEntry(to itemID: String, title: String) -> ChecklistEntry? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let entry = ChecklistEntry(id: ShortID.make(10), itemID: itemID, title: title, done: false,
                                   position: (items[index].checklist.map(\.position).max() ?? -1) + 1)
        do {
            try insertChecklist(entry)
            items[index].checklist.append(entry)
            touch(index)
            return entry
        } catch {
            report(error)
            return nil
        }
    }

    func updateChecklistEntry(_ entry: ChecklistEntry, author: Author = .user) {
        guard let index = items.firstIndex(where: { $0.id == entry.itemID }),
              let ci = items[index].checklist.firstIndex(where: { $0.id == entry.id }) else { return }
        let old = items[index].checklist[ci]
        do {
            try db.execute("UPDATE checklist SET title = ?, done = ? WHERE id = ?", [entry.title, entry.done, entry.id])
            items[index].checklist[ci] = entry
            touch(index)
            if old.done != entry.done, entry.done {
                let p = items[index].checklistProgress
                log(item: entry.itemID, project: items[index].projectID, kind: "update",
                    text: "Checked “\(entry.title)” (\(p.done)/\(p.total))", author: author)
            }
        } catch {
            report(error)
        }
    }

    func removeChecklistEntry(_ entry: ChecklistEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.itemID }) else { return }
        do {
            try db.execute("DELETE FROM checklist WHERE id = ?", [entry.id])
            items[index].checklist.removeAll { $0.id == entry.id }
            touch(index)
        } catch {
            report(error)
        }
    }

    private func touch(_ index: Int) {
        items[index].updatedAt = Date()
        try? db.execute("UPDATE items SET updated_at = ? WHERE id = ?", [items[index].updatedAt, items[index].id])
    }

    // MARK: Projects

    @discardableResult
    func createProject(_ draft: Project, author: Author = .user) -> Project {
        var p = draft
        if p.id.isEmpty || project(p.id) != nil { p.id = ShortID.make() }
        p.createdAt = Date()
        p.updatedAt = p.createdAt
        do {
            try db.execute(
                "INSERT INTO projects (id, name, summary, color, symbol, status, deadline, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                [p.id, p.name, p.summary, p.color, p.symbol, p.status.rawValue, p.deadline, p.createdAt, p.updatedAt]
            )
            projects.append(p)
            log(item: nil, project: p.id, kind: "created", text: "Created project “\(p.name)”", author: author)
        } catch {
            report(error)
        }
        return p
    }

    func updateProject(_ updated: Project, author: Author = .user) {
        guard let index = projects.firstIndex(where: { $0.id == updated.id }), projects[index] != updated else { return }
        let old = projects[index]
        var p = updated
        p.updatedAt = Date()
        do {
            try db.execute(
                "UPDATE projects SET name = ?, summary = ?, color = ?, symbol = ?, status = ?, deadline = ?, updated_at = ? WHERE id = ?",
                [p.name, p.summary, p.color, p.symbol, p.status.rawValue, p.deadline, p.updatedAt, p.id]
            )
            projects[index] = p
            if old.status != p.status {
                log(item: nil, project: p.id, kind: "status", text: "Project \(old.status.label) → \(p.status.label)", author: author)
            }
        } catch {
            report(error)
        }
    }

    func deleteProject(_ id: String) {
        do {
            try db.execute("DELETE FROM projects WHERE id = ?", [id])
            projects.removeAll { $0.id == id }
            for i in items.indices where items[i].projectID == id { items[i].projectID = nil }
            logRevision += 1
        } catch {
            report(error)
        }
    }

    // MARK: Activity log

    func log(item: String?, project: String?, kind: String, text: String, author: Author) {
        do {
            try db.execute(
                "INSERT INTO logs (id, item_id, project_id, kind, text, author, created_at) VALUES (?,?,?,?,?,?,?)",
                [ShortID.make(12), item, project, kind, text, author.rawValue, Date()]
            )
            logRevision += 1
        } catch {
            report(error)
        }
    }

    func addNote(_ text: String, itemID: String, author: Author = .user) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        log(item: itemID, project: items[index].projectID, kind: "note", text: text, author: author)
        touch(index)
    }

    func logs(forItem id: String, limit: Int = 200) -> [LogEntry] {
        _ = logRevision
        return (try? db.query("SELECT * FROM logs WHERE item_id = ? ORDER BY created_at DESC LIMIT ?", [id, limit]))?
            .map(Self.log(from:)) ?? []
    }

    func logs(since date: Date, projectID: String? = nil, limit: Int = 500) -> [LogEntry] {
        _ = logRevision
        let rows: [Row]?
        if let projectID {
            rows = try? db.query("""
                SELECT l.* FROM logs l LEFT JOIN items i ON i.id = l.item_id
                WHERE l.created_at >= ? AND (l.project_id = ? OR i.project_id = ?)
                ORDER BY l.created_at DESC LIMIT ?
                """, [date, projectID, projectID, limit])
        } else {
            rows = try? db.query("SELECT * FROM logs WHERE created_at >= ? ORDER BY created_at DESC LIMIT ?", [date, limit])
        }
        return rows?.map(Self.log(from:)) ?? []
    }

    // MARK: Row mapping

    private static let itemColumns = [
        "id", "title", "notes", "kind", "status", "priority", "project_id", "tags", "due_date", "flagged_today",
        "created_at", "updated_at", "completed_at", "repo", "branch", "link", "hypothesis", "setup", "compute",
        "results", "conclusion", "outcome", "metrics", "run_started_at", "run_ended_at", "position",
    ]

    private static func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "[]"
    }

    private static func itemParams(_ i: Item) -> [SQLConvertible] {
        [i.id, i.title, i.notes, i.kind.rawValue, i.status.rawValue, i.priority.rawValue, i.projectID, json(i.tags),
         i.dueDate, i.flaggedToday, i.createdAt, i.updatedAt, i.completedAt, i.repo, i.branch, i.link, i.hypothesis,
         i.setup, i.compute, i.results, i.conclusion, i.outcome.rawValue, json(i.metrics), i.runStartedAt, i.runEndedAt,
         i.position]
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ s: String?, default value: T) -> T {
        guard let data = s?.data(using: .utf8) else { return value }
        return (try? JSONDecoder().decode(type, from: data)) ?? value
    }

    private static func item(from r: Row) -> Item {
        Item(
            id: r["id"]?.string ?? "",
            title: r["title"]?.string ?? "",
            notes: r["notes"]?.string ?? "",
            kind: ItemKind(rawValue: r["kind"]?.string ?? "") ?? .task,
            status: ItemStatus(rawValue: r["status"]?.string ?? "") ?? .todo,
            priority: Priority(rawValue: r["priority"]?.int ?? 0) ?? .none,
            projectID: r["project_id"]?.string,
            tags: decode([String].self, r["tags"]?.string, default: []),
            dueDate: r["due_date"]?.date,
            flaggedToday: (r["flagged_today"]?.int ?? 0) != 0,
            createdAt: r["created_at"]?.date ?? Date(),
            updatedAt: r["updated_at"]?.date ?? Date(),
            completedAt: r["completed_at"]?.date,
            position: r["position"]?.double ?? 0,
            repo: r["repo"]?.string ?? "",
            branch: r["branch"]?.string ?? "",
            link: r["link"]?.string ?? "",
            hypothesis: r["hypothesis"]?.string ?? "",
            setup: r["setup"]?.string ?? "",
            compute: r["compute"]?.string ?? "",
            results: r["results"]?.string ?? "",
            conclusion: r["conclusion"]?.string ?? "",
            outcome: ExperimentOutcome(rawValue: r["outcome"]?.string ?? "") ?? .pending,
            metrics: decode([Metric].self, r["metrics"]?.string, default: []),
            runStartedAt: r["run_started_at"]?.date,
            runEndedAt: r["run_ended_at"]?.date
        )
    }

    private static func checklist(from r: Row) -> ChecklistEntry {
        ChecklistEntry(id: r["id"]?.string ?? "", itemID: r["item_id"]?.string ?? "", title: r["title"]?.string ?? "",
                       done: (r["done"]?.int ?? 0) != 0, position: r["position"]?.int ?? 0)
    }

    private static func project(from r: Row) -> Project {
        Project(id: r["id"]?.string ?? "", name: r["name"]?.string ?? "", summary: r["summary"]?.string ?? "",
                color: r["color"]?.string ?? "blue", symbol: r["symbol"]?.string ?? "folder",
                status: ProjectStatus(rawValue: r["status"]?.string ?? "") ?? .active, deadline: r["deadline"]?.date,
                createdAt: r["created_at"]?.date ?? Date(), updatedAt: r["updated_at"]?.date ?? Date())
    }

    private static func log(from r: Row) -> LogEntry {
        LogEntry(id: r["id"]?.string ?? "", itemID: r["item_id"]?.string, projectID: r["project_id"]?.string,
                 kind: r["kind"]?.string ?? "note", text: r["text"]?.string ?? "",
                 author: Author(rawValue: r["author"]?.string ?? "") ?? .user, createdAt: r["created_at"]?.date ?? Date())
    }

    private static func changedFields(_ a: Item, _ b: Item) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ name: String, _ kp: KeyPath<Item, T>) { if a[keyPath: kp] != b[keyPath: kp] { out.append(name) } }
        check("title", \.title); check("notes", \.notes); check("kind", \.kind); check("status", \.status)
        check("priority", \.priority); check("project", \.projectID); check("tags", \.tags); check("due date", \.dueDate)
        check("today flag", \.flaggedToday); check("repo", \.repo); check("branch", \.branch); check("link", \.link)
        check("hypothesis", \.hypothesis); check("setup", \.setup); check("compute", \.compute); check("results", \.results)
        check("conclusion", \.conclusion); check("outcome", \.outcome); check("metrics", \.metrics)
        check("run start", \.runStartedAt); check("run end", \.runEndedAt)
        return out
    }
}

// MARK: - Queries used by the sidebar, lists, and review

enum SidebarSelection: Hashable {
    case today, inbox, upcoming, all, review, logbook
    case kind(ItemKind)
    case project(String)

    /// How an item changes when dropped or pasted onto this list.
    var placement: Placement {
        switch self {
        case .today: Placement(today: true)
        case .inbox: Placement(status: .inbox)
        case .kind(let k): Placement(kind: k)
        case .project(let id): Placement(projectID: id)
        case .logbook: Placement(status: .done)
        case .upcoming, .all, .review: Placement()
        }
    }

    /// Upcoming and Logbook are ordered by date, so they can't be rearranged by hand.
    var supportsManualOrder: Bool {
        switch self {
        case .upcoming, .logbook, .review: false
        default: true
        }
    }

    /// Lists that accept items dragged onto them in the sidebar.
    var acceptsDrops: Bool {
        switch self {
        case .upcoming, .all, .review: false
        default: true
        }
    }
}

extension Store {
    static func sortKey(_ a: Item, _ b: Item) -> Bool {
        if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.createdAt > b.createdAt
        }
    }

    static func manualOrder(_ a: Item, _ b: Item) -> Bool {
        a.position != b.position ? a.position < b.position : a.createdAt > b.createdAt
    }

    static func comparator(_ order: SortOrder) -> (Item, Item) -> Bool {
        switch order {
        case .manual: manualOrder
        case .priority: sortKey
        case .dueDate: { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: x < y
            case (_?, nil): true
            case (nil, _?): false
            default: manualOrder(a, b)
            }
        }
        case .title: { a, b in
            let r = a.title.localizedStandardCompare(b.title)
            return r == .orderedSame ? manualOrder(a, b) : r == .orderedAscending
        }
        }
    }

    func items(for selection: SidebarSelection, search: String = "", order: SortOrder = .priority) -> [Item] {
        var result: [Item]
        switch selection {
        case .today:
            result = items.filter { $0.status.isOpen && $0.status != .inbox && ($0.flaggedToday || $0.isDueTodayOrEarlier || $0.status == .inProgress) }
        case .inbox:
            result = items.filter { $0.status == .inbox }
        case .upcoming:
            let tomorrow = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
            result = items.filter { $0.status.isOpen && ($0.dueDate.map { $0 >= tomorrow } ?? false) }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            return filtered(result, search)
        case .all:
            result = items.filter { $0.status != .dropped }
        case .logbook:
            result = items.filter { !$0.status.isOpen }
                .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
            return filtered(result, search)
        case .review:
            result = []
        case .kind(let kind):
            result = items.filter { $0.kind == kind && $0.status != .dropped }
        case .project(let id):
            result = items.filter { $0.projectID == id && $0.status != .dropped }
        }
        return filtered(result.sorted(by: Self.comparator(order)), search)
    }

    private func filtered(_ list: [Item], _ search: String) -> [Item] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(q) || $0.notes.lowercased().contains(q)
                || $0.tags.contains { $0.lowercased().contains(q) } || $0.id == q
        }
    }

    func count(for selection: SidebarSelection) -> Int {
        switch selection {
        case .review, .logbook, .upcoming: 0
        case .kind(let k): items.filter { $0.kind == k && $0.status.isOpen }.count
        case .project(let id): items.filter { $0.projectID == id && $0.status.isOpen }.count
        default: items(for: selection).count
        }
    }

    /// (closed, total) for open + recently relevant items of a kind, optionally scoped to a project.
    func progress(kind: ItemKind?, projectID: String? = nil) -> (done: Int, total: Int) {
        let scoped = items.filter {
            $0.status != .dropped && (kind == nil || $0.kind == kind) && (projectID == nil || $0.projectID == projectID)
        }
        return (scoped.filter { $0.status == .done }.count, scoped.count)
    }
}
