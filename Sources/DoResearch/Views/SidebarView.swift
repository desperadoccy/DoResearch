import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @State private var editingProject: Project?
    @State private var deletingProject: Project?
    @State private var dropTarget: SidebarSelection?

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
                ForEach(ProjectType.research.kinds) { kind in
                    row(.kind(kind), kind.pluralLabel, kind.symbol, kind.color)
                }
            }

            Section("Life") {
                ForEach(ProjectType.personal.kinds + ProjectType.misc.kinds) { kind in
                    row(.kind(kind), kind.pluralLabel, kind.symbol, kind.color)
                }
            }

            projectsSection

            Section {
                row(.all, "All Items", "square.stack", .secondary)
                row(.logbook, "Logbook", "book.closed", .secondary)
            }
        }
        .listStyle(.sidebar)
        .onPasteCommand(of: ItemActions.dropTypes) { _ in
            ItemActions(store: store, app: app).paste()
        }
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

    /// Every project in one list, whatever its type; the project's icon and color tell them apart.
    private var projectsSection: some View {
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
                Menu {
                    ForEach(ProjectType.allCases) { type in
                        Button {
                            app.newProject(type)
                        } label: {
                            Label("\(type.label) Project…", systemImage: type.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New Project (⇧⌘N)")
            }
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
        .modifier(SidebarDropTarget(selection: selection, target: $dropTarget))
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
        .help("\(project.type.label) project")
        .tag(SidebarSelection.project(project.id))
        .modifier(SidebarDropTarget(selection: .project(project.id), target: $dropTarget))
        .contextMenu {
            Button("Edit Project…") { editingProject = project }
            Menu("Type") {
                ForEach(ProjectType.allCases) { type in
                    Toggle(type.label, isOn: Binding(get: { project.type == type }, set: { on in
                        guard on else { return }
                        var p = project
                        p.type = type
                        store.updateProject(p)
                    }))
                }
            }
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

/// Lets items be dragged onto a sidebar list: onto a project to file them there, a kind to change their kind,
/// Today to flag them, Inbox to untriage, Logbook to complete. Hold Option to copy instead of move.
private struct SidebarDropTarget: ViewModifier {
    let selection: SidebarSelection
    @Binding var target: SidebarSelection?
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        if selection.acceptsDrops {
            content
                .onDrop(of: ItemActions.dropTypes, isTargeted: Binding(
                    get: { target == selection },
                    set: { target = $0 ? selection : (target == selection ? nil : target) }
                )) { providers in
                    ItemActions(store: store, app: app).drop(providers, placement: selection.placement, select: false)
                }
                .listRowBackground(
                    target == selection ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25)).padding(.horizontal, 10) : nil
                )
        } else {
            content
        }
    }
}
