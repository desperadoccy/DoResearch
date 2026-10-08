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
    case user, agent
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

    var statusLabel: String { status.label(for: kind) }

    var checklistProgress: (done: Int, total: Int) {
        (checklist.filter(\.done).count, checklist.count)
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

enum ProjectStatus: String, CaseIterable, Identifiable, Codable {
    case active, paused, done, archived
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct Project: Identifiable, Hashable {
    var id: String
    var name: String
    var summary = ""
    var color = "blue"
    var symbol = "folder"
    var status: ProjectStatus = .active
    var deadline: Date?
    var createdAt = Date()
    var updatedAt = Date()

    static let palette: [String] = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "indigo", "gray"]
    static let symbols: [String] = [
        "folder", "brain", "cpu", "network", "server.rack", "function", "chart.xyaxis.line",
        "doc.text", "graduationcap", "lightbulb", "atom", "lock.shield", "globe", "camera.aperture",
    ]

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
