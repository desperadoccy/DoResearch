import SwiftUI

// MARK: - Kinds

enum ItemKind: String, CaseIterable, Identifiable, Codable {
    case coding, experiment, writing, reading, task, personal, misc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coding: "Coding"
        case .experiment: "Experiment"
        case .writing: "Writing"
        case .reading: "Reading"
        case .task: "Task"
        case .personal: "Personal"
        case .misc: "Misc"
        }
    }

    var pluralLabel: String {
        switch self {
        case .coding: "Coding"
        case .experiment: "Experiments"
        case .writing: "Writing"
        case .reading: "Reading"
        case .task: "Tasks"
        case .personal: "Personal"
        case .misc: "Misc"
        }
    }

    var symbol: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .experiment: "flask"
        case .writing: "doc.richtext"
        case .reading: "books.vertical"
        case .task: "checklist"
        case .personal: "person"
        case .misc: "tray.full"
        }
    }

    var color: Color {
        switch self {
        case .coding: .blue
        case .experiment: .purple
        case .writing: .orange
        case .reading: .teal
        case .task: .indigo
        case .personal: .pink
        case .misc: .gray
        }
    }

    var isResearch: Bool { [.coding, .experiment, .writing, .reading, .task].contains(self) }
}

// MARK: - Status

/// One shared status set; each kind gets its own vocabulary for display.
enum ItemStatus: String, CaseIterable, Identifiable, Codable {
    case inbox, todo, inProgress = "in_progress", waiting, blocked, done, dropped

    var id: String { rawValue }

    var isOpen: Bool { self != .done && self != .dropped }

    static let boardColumns: [ItemStatus] = [.todo, .inProgress, .waiting, .blocked, .done]

    func label(for kind: ItemKind) -> String {
        switch (self, kind) {
        case (.inbox, _): "Inbox"
        case (.todo, .experiment): "Planned"
        case (.inProgress, .experiment): "Running"
        case (.waiting, .experiment): "Analyzing"
        case (.done, .experiment): "Concluded"
        case (.inProgress, .coding): "In Development"
        case (.waiting, .coding): "In Review"
        case (.done, .coding): "Merged"
        case (.inProgress, .writing): "Drafting"
        case (.waiting, .writing): "Revising"
        case (.inProgress, .reading): "Reading"
        case (.done, .reading): "Read"
        case (.todo, _): "To Do"
        case (.inProgress, _): "In Progress"
        case (.waiting, _): "Waiting"
        case (.blocked, _): "Blocked"
        case (.done, _): "Done"
        case (.dropped, _): "Dropped"
        }
    }

    var genericLabel: String { label(for: .task) }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .waiting: "hourglass.circle"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        case .dropped: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .inbox: .secondary
        case .todo: .secondary
        case .inProgress: .blue
        case .waiting: .orange
        case .blocked: .red
        case .done: .green
        case .dropped: .gray
        }
    }
}

enum Priority: Int, CaseIterable, Identifiable, Codable {
    case none = 0, low, medium, high

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
    var name: String { label.lowercased() }
    var marks: String { String(repeating: "!", count: rawValue) }
}

enum ExperimentOutcome: String, CaseIterable, Identifiable, Codable {
    case pending, supported, refuted, inconclusive, failed

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .pending: .secondary
        case .supported: .green
        case .refuted: .red
        case .inconclusive: .orange
        case .failed: .gray
        }
    }
    var symbol: String {
        switch self {
        case .pending: "ellipsis.circle"
        case .supported: "checkmark.seal"
        case .refuted: "xmark.seal"
        case .inconclusive: "questionmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

enum Author: String, Codable {
    /// `api` marks changes made by external clients through the local API (see docs/API.md).
    case user, agent, api
}

// MARK: - Records

struct Metric: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var value: String

    enum CodingKeys: String, CodingKey { case name, value }
}

struct ChecklistEntry: Identifiable, Hashable, Codable {
    var id: String
    var itemID: String
    var title: String
    var done: Bool
    var position: Int
}

struct Item: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var notes: String = ""
    var kind: ItemKind = .task
    var status: ItemStatus = .todo
    var priority: Priority = .none
    var projectID: String?
    var tags: [String] = []
    var dueDate: Date?
    var flaggedToday = false
    var createdAt = Date()
    var updatedAt = Date()
    var completedAt: Date?
    /// Manual sort order shared by every list (lower comes first). Changed only by reordering, never by edits.
    var position: Double = 0

    // Coding
    var repo = ""
    var branch = ""
    var link = ""

    // Experiment
    var hypothesis = ""
    var setup = ""
    var compute = ""
    var results = ""
    var conclusion = ""
    var outcome: ExperimentOutcome = .pending
    var metrics: [Metric] = []
    var runStartedAt: Date?
    var runEndedAt: Date?

    var checklist: [ChecklistEntry] = []

    /// Bumped on every saved change to the item's content, so API clients can detect edits made since they read it.
    var revision = 1
    /// Ids of external chats (e.g. Codex conversations) working on this item. Set through the local API.
    var chatIDs: [String] = []

    // Measurable progress, e.g. 4 of 10 papers read. Tracked only while a target is set.
    var progressCurrent = 0
    var progressTarget: Int?
    var progressUnit = ""

    var statusLabel: String { status.label(for: kind) }

    var checklistProgress: (done: Int, total: Int) {
        (checklist.filter(\.done).count, checklist.count)
    }

    var tracksProgress: Bool { progressTarget != nil }

    /// "4/10 papers"
    var progressLabel: String {
        guard let progressTarget else { return "" }
        let unit = progressUnit.trimmingCharacters(in: .whitespaces)
        return "\(progressCurrent)/\(progressTarget)" + (unit.isEmpty ? "" : " \(unit)")
    }

    var isOverdue: Bool {
        guard let dueDate, status.isOpen else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date())
    }

    var isDueTodayOrEarlier: Bool {
        guard let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
    }
}

// MARK: - Ordering and placement

enum SortOrder: String, CaseIterable, Identifiable {
    case manual, priority, dueDate, title

    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Manual"
        case .priority: "Priority"
        case .dueDate: "Due Date"
        case .title: "Title"
        }
    }
}

/// What happens to an item when it is dropped or pasted somewhere. `nil` fields leave the item unchanged.
struct Placement: Equatable {
    var kind: ItemKind?
    var projectID: String?
    var status: ItemStatus?
    var today: Bool?

    func apply(to item: inout Item) {
        if let kind { item.kind = kind }
        if let projectID { item.projectID = projectID }
        if let status { item.status = status }
        if let today {
            item.flaggedToday = today
            // Today never shows untriaged items, so landing there triages it.
            if today, item.status == .inbox { item.status = .todo }
        }
    }

    /// Section-level rules win over list-level ones.
    func merged(with section: Placement) -> Placement {
        Placement(kind: section.kind ?? kind, projectID: section.projectID ?? projectID,
                  status: section.status ?? status, today: section.today ?? today)
    }
}

/// What a project organizes. Decides which kind new items get, and how progress is shown.
enum ProjectType: String, CaseIterable, Identifiable, Codable {
    case research, personal, misc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .research: "Research"
        case .personal: "Personal"
        case .misc: "Misc"
        }
    }

    var symbol: String {
        switch self {
        case .research: "graduationcap"
        case .personal: "person.crop.circle"
        case .misc: "tray.full"
        }
    }

    var summary: String {
        switch self {
        case .research: "A paper, research thread, or system. Tracks coding, experiments, and writing separately."
        case .personal: "An area of your life such as health, finances, a trip, or a move. Can be ongoing."
        case .misc: "A group for everything else: errands, admin, service duties, side tasks."
        }
    }

    var namePrompt: String {
        switch self {
        case .research: "e.g. Sparse Attention Paper"
        case .personal: "e.g. Health, Apartment Move, Japan Trip"
        case .misc: "e.g. Errands, Reviewing Duties, Admin"
        }
    }

    /// Kind given to items created inside a project of this type.
    var defaultKind: ItemKind {
        switch self {
        case .research: .task
        case .personal: .personal
        case .misc: .misc
        }
    }

    /// Item kinds that belong to this type.
    var kinds: [ItemKind] {
        switch self {
        case .research: [.coding, .experiment, .writing, .reading, .task]
        case .personal: [.personal]
        case .misc: [.misc]
        }
    }

    var defaultColor: String {
        switch self {
        case .research: "blue"
        case .personal: "pink"
        case .misc: "gray"
        }
    }

    var symbols: [String] {
        switch self {
        case .research:
            ["folder", "brain", "cpu", "network", "server.rack", "function", "chart.xyaxis.line",
             "doc.text", "graduationcap", "lightbulb", "atom", "lock.shield", "globe", "camera.aperture"]
        case .personal:
            ["heart", "figure.run", "house", "airplane", "cart", "dollarsign.circle", "stethoscope",
             "book", "gift", "person.2", "fork.knife", "leaf", "pawprint", "music.note"]
        case .misc:
            ["tray.full", "wrench.and.screwdriver", "envelope", "calendar", "shippingbox", "paperclip", "archivebox",
             "list.bullet.clipboard", "creditcard", "car", "hammer", "star", "person.3", "building.columns"]
        }
    }

    var defaultSymbol: String { symbols[0] }

    /// The project type an item kind naturally belongs to.
    init(kind: ItemKind) {
        switch kind {
        case .personal: self = .personal
        case .misc: self = .misc
        default: self = .research
        }
    }
}

enum ProjectStatus: String, CaseIterable, Identifiable, Codable {
    case active, paused, done, archived
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Project: Identifiable, Hashable {
    var id: String
    var name: String
    var type: ProjectType = .research
    var summary = ""
    var color = "blue"
    var symbol = "folder"
    var status: ProjectStatus = .active
    var deadline: Date?
    var createdAt = Date()
    var updatedAt = Date()
    /// Bumped on every saved change, like `Item.revision`.
    var revision = 1

    static let palette: [String] = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "indigo", "gray"]
    /// Every icon any project type offers (the assistant may pick any of them).
    static let symbols: [String] = ProjectType.allCases.flatMap(\.symbols).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

    init(id: String, name: String, type: ProjectType = .research) {
        self.id = id
        self.name = name
        self.type = type
        color = type.defaultColor
        symbol = type.defaultSymbol
    }

    init(id: String, name: String, type: ProjectType, summary: String, color: String, symbol: String,
         status: ProjectStatus, deadline: Date?, createdAt: Date, updatedAt: Date, revision: Int = 1) {
        self.id = id
        self.name = name
        self.type = type
        self.summary = summary
        self.color = color
        self.symbol = symbol
        self.status = status
        self.deadline = deadline
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    var swiftColor: Color { Color.named(color) }
}

struct LogEntry: Identifiable, Hashable {
    var id: String
    var itemID: String?
    var projectID: String?
    var kind: String // created | status | note | update
    var text: String
    var author: Author
    var createdAt: Date
    /// Set for entries appended through the local API.
    var sourceChatID: String?
    var idempotencyKey: String?
}

extension Color {
    static func named(_ name: String) -> Color {
        switch name {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "indigo": .indigo
        case "gray": .gray
        default: .blue
        }
    }
}

enum ShortID {
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    static func make(_ length: Int = 8) -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }
}
