import SwiftUI

struct ProjectHeader: View {
    let project: Project
    @Environment(Store.self) private var store
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: project.symbol)
                    .font(.title)
                    .foregroundStyle(project.swiftColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(project.name).font(.title2.weight(.semibold))
                        ProjectTypeBadge(type: project.type)
                        if project.status != .active {
                            Text(project.status.label)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if !project.summary.isEmpty {
                        Text(project.summary).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if let deadline = project.deadline {
                        Label("Deadline \(deadline.formatted(date: .abbreviated, time: .omitted)) · \(deadline.formatted(.relative(presentation: .named)))",
                              systemImage: "flag.checkered")
                            .font(.caption)
                            .foregroundStyle(deadline < Date() ? .red : .secondary)
                    }
                }
                Spacer()
                Button("Edit…") { editing = true }
                    .controlSize(.small)
            }
            ProjectProgress(project: project)
        }
        .padding(14)
        .sheet(isPresented: $editing) { ProjectEditor(project: project) }
    }
}

struct ProjectTypeBadge: View {
    let type: ProjectType

    var body: some View {
        Label(type.label, systemImage: type.symbol)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Research projects show coding / experiment / writing progress side by side. Personal and misc projects are often
/// ongoing (Health, Errands), so a completion bar would mislead; they show what's open, recently done, and due.
struct ProjectProgress: View {
    let project: Project
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    var body: some View {
        switch project.type {
        case .research:
            HStack(spacing: 16) {
                ForEach([ItemKind.coding, .experiment, .writing], id: \.self) { kind in
                    KindProgress(kind: kind, progress: store.progress(kind: kind, projectID: project.id))
                }
            }
        case .personal, .misc:
            let pulse = store.pulse(projectID: project.id)
            HStack(spacing: 14) {
                stat("\(pulse.open)", "open", "circle", .secondary)
                stat("\(pulse.doneThisWeek)", "done this week", "checkmark.circle", .green)
                if pulse.overdue > 0 {
                    stat("\(pulse.overdue)", "overdue", "exclamationmark.circle", .red)
                }
                if let next = pulse.nextDue, let due = next.dueDate {
                    Button {
                        app.selectedItemID = next.id
                    } label: {
                        Label("Next: \(next.title) · \(due.formatted(.relative(presentation: .named)))", systemImage: "calendar")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(next.isOverdue ? .red : .secondary)
                    .help("Select the next item that's due")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text("\(Text(value).monospacedDigit().foregroundStyle(.primary)) \(label)").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct KindProgress: View {
    let kind: ItemKind
    let progress: (done: Int, total: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(kind.pluralLabel, systemImage: kind.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(kind.color)
                Spacer()
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .tint(kind.color)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProjectEditor: View {
    let project: Project?
    /// Type for a new project.
    var initialType: ProjectType = .research
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = Project(id: "", name: "")
    @State private var hasDeadline = false
    @State private var moveItemsToKind = false

    /// Items in this project whose kind belongs to a different type than the one being chosen.
    private var mismatchedItems: [Item] {
        guard let project else { return [] }
        return store.items.filter { $0.projectID == project.id && ProjectType(kind: $0.kind) != draft.type }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: Binding(get: { draft.type }, set: changeType)) {
                        ForEach(ProjectType.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(draft.type.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if project != nil, project?.type != draft.type, !mismatchedItems.isEmpty, draft.type != .research {
                        Toggle("Also change its \(mismatchedItems.count) item\(mismatchedItems.count == 1 ? "" : "s") to \(draft.type.defaultKind.label)",
                               isOn: $moveItemsToKind)
                    }
                }
                Section {
                    TextField("Name", text: $draft.name, prompt: Text(draft.type.namePrompt))
                    TextField("Summary", text: $draft.summary, prompt: Text(draft.type == .research ? "Goal, venue, scope" : "What this covers"),
                              axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Status", selection: $draft.status) {
                        ForEach(ProjectStatus.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle(draft.type == .research ? "Deadline" : "Target date", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Date", selection: Binding(
                            get: { draft.deadline ?? Date().addingTimeInterval(30 * 86_400) },
                            set: { draft.deadline = $0 }
                        ), displayedComponents: .date)
                    }
                }
                Section {
                    LabeledContent("Color") {
                        HStack(spacing: 6) {
                            ForEach(Project.palette, id: \.self) { name in
                                Circle()
                                    .fill(Color.named(name))
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(.primary.opacity(draft.color == name ? 0.8 : 0), lineWidth: 2))
                                    .onTapGesture { draft.color = name }
                            }
                        }
                    }
                    LabeledContent("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26)), count: 7), spacing: 6) {
                            ForEach(iconChoices, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .frame(width: 26, height: 26)
                                    .background(draft.symbol == symbol ? Color.named(draft.color).opacity(0.25) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(Color.named(draft.color))
                                    .onTapGesture { draft.symbol = symbol }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(project == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear {
            if let project {
                draft = project
                hasDeadline = project.deadline != nil
            } else {
                draft = Project(id: "", name: "", type: initialType)
            }
        }
    }

    /// The type's icons, plus the current one if it came from another type.
    private var iconChoices: [String] {
        let base = draft.type.symbols
        return base.contains(draft.symbol) ? base : [draft.symbol] + base.prefix(base.count - 1)
    }

    /// Switching type swaps in that type's look, unless the user already customized it.
    private func changeType(_ type: ProjectType) {
        let old = draft.type
        if draft.symbol == old.defaultSymbol { draft.symbol = type.defaultSymbol }
        if draft.color == old.defaultColor { draft.color = type.defaultColor }
        draft.type = type
    }

    private func save() {
        if !hasDeadline { draft.deadline = nil } else if draft.deadline == nil { draft.deadline = Date().addingTimeInterval(30 * 86_400) }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if project == nil {
            let created = store.createProject(draft)
            app.selection = .project(created.id)
        } else {
            if moveItemsToKind, draft.type != .research {
                for var item in mismatchedItems {
                    item.kind = draft.type.defaultKind
                    store.updateItem(item)
                }
            }
            store.updateProject(draft)
        }
        dismiss()
    }
}
