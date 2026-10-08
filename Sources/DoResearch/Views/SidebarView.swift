import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @State private var editingProject: Project?
    @State private var deletingProject: Project?

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section {
                row(.today, "Today", "star.fill", .yellow)
                row(.inbox, "Inbox", "tray.fill", .blue)
                row(.upcoming, "Upcoming", "calendar", .red)
                row(.review, "Review", "chart.bar.doc.horizontal", .green)
            }

            Section("Research") {
                ForEach([ItemKind.coding, .experiment, .writing, .reading, .task]) { kind in
                    row(.kind(kind), kind.pluralLabel, kind.symbol, kind.color)
                }
            }

            Section("Life") {
                ForEach([ItemKind.personal, .misc]) { kind in
                    row(.kind(kind), kind.pluralLabel, kind.symbol, kind.color)
                }
            }

            Section {
                ForEach(store.projects.filter { $0.status != .archived }) { project in
                    projectRow(project)
                }
                let archived = store.projects.filter { $0.status == .archived }
                if !archived.isEmpty {
                    DisclosureGroup("Archived") {
                        ForEach(archived) { projectRow($0) }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button {
                        app.showingNewProject = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Project (⇧⌘N)")
                }
            }

            Section {
                row(.all, "All Items", "square.stack", .secondary)
                row(.logbook, "Logbook", "book.closed", .secondary)
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $editingProject) { ProjectEditor(project: $0) }
        .confirmationDialog(
            "Delete “\(deletingProject?.name ?? "")”?",
            isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            presenting: deletingProject
        ) { project in
            Button("Delete Project", role: .destructive) {
                if app.selection == .project(project.id) { app.selection = .today }
                store.deleteProject(project.id)
            }
        } message: { _ in
            Text("Items in this project are kept and become unassigned.")
        }
    }

    private func row(_ selection: SidebarSelection, _ title: String, _ symbol: String, _ color: Color) -> some View {
        let count = store.count(for: selection)
        return Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .badge(count > 0 ? count : 0)
        .tag(selection)
    }

    private func projectRow(_ project: Project) -> some View {
        let count = store.count(for: .project(project.id))
        return Label {
            Text(project.name)
                .foregroundStyle(project.status == .active ? .primary : .secondary)
        } icon: {
            Image(systemName: project.symbol).foregroundStyle(project.swiftColor)
        }
        .badge(count)
        .tag(SidebarSelection.project(project.id))
        .contextMenu {
            Button("Edit Project…") { editingProject = project }
            Menu("Status") {
                ForEach(ProjectStatus.allCases) { status in
                    Button(status.label) {
                        var p = project
                        p.status = status
                        store.updateProject(p)
                    }
                }
            }
            Divider()
            Button("Delete Project…", role: .destructive) { deletingProject = project }
        }
    }
}
