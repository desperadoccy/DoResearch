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
            HStack(spacing: 16) {
                ForEach([ItemKind.coding, .experiment, .writing], id: \.self) { kind in
                    KindProgress(kind: kind, progress: store.progress(kind: kind, projectID: project.id))
                }
            }
        }
        .padding(14)
        .sheet(isPresented: $editing) { ProjectEditor(project: project) }
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
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var draft = Project(id: "", name: "")
    @State private var hasDeadline = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Sparse Attention Paper"))
                TextField("Summary", text: $draft.summary, prompt: Text("Goal, venue, scope"), axis: .vertical)
                    .lineLimit(2...5)
                Picker("Status", selection: $draft.status) {
                    ForEach(ProjectStatus.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Deadline", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("Date", selection: Binding(
                        get: { draft.deadline ?? Date().addingTimeInterval(30 * 86_400) },
                        set: { draft.deadline = $0 }
                    ), displayedComponents: .date)
                }
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
                        ForEach(Project.symbols, id: \.self) { symbol in
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
        .frame(width: 460)
        .onAppear {
            if let project {
                draft = project
                hasDeadline = project.deadline != nil
            }
        }
    }

    private func save() {
        if !hasDeadline { draft.deadline = nil } else if draft.deadline == nil { draft.deadline = Date().addingTimeInterval(30 * 86_400) }
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if project == nil {
            let created = store.createProject(draft)
            app.selection = .project(created.id)
        } else {
            store.updateProject(draft)
        }
        dismiss()
    }
}
