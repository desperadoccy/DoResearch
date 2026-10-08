import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(AgentSession.self) private var agent

    /// Review spans the full width; every other selection uses list + detail columns.
    @ViewBuilder
    private var splitView: some View {
        if app.selection == .review {
            NavigationSplitView {
                sidebar
            } detail: {
                ReviewView()
                    .modifier(AssistantToolbar())
            }
        } else {
            NavigationSplitView {
                sidebar
            } content: {
                Group {
                    if let selection = app.selection {
                        ItemListView(selection: selection)
                    } else {
                        ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
                    }
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
            } detail: {
                Group {
                    if let id = app.selectedItemID, store.item(id) != nil {
                        ItemDetailView(itemID: id)
                            .id(id)
                    } else if app.selectedItemIDs.count > 1 {
                        MultiSelectionView(ids: app.selectedItemIDs)
                    } else {
                        ContentUnavailableView("No Item Selected", systemImage: "square.dashed",
                                               description: Text("Select an item to see its details, or press ⌘N to add one."))
                    }
                }
                .modifier(AssistantToolbar())
            }
        }
    }

    private var sidebar: some View {
        SidebarView()
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    var body: some View {
        @Bindable var app = app
        splitView
        .inspector(isPresented: $app.showAgent) {
            AgentChatView()
                .inspectorColumnWidth(min: 320, ideal: Self.inspectorWidth, max: 560)
        }
        .onChange(of: app.showAgent) { _, shown in
            if shown { Self.growWindowForInspector() }
        }
        .searchable(text: $app.search, placement: .sidebar, prompt: "Search items")
        .sheet(isPresented: $app.showingNewProject) {
            ProjectEditor(project: nil)
        }
        .onAppear {
            agent.contextProvider = { [store, app] in AgentChatView.context(store: store, app: app) }
        }
        .onChange(of: app.selection) { _, new in
            // Keep only the selected items that are still visible in the new list.
            guard let new, new != .review else { app.selectedItemIDs = []; return }
            let visible = Set(store.items(for: new).map(\.id))
            app.selectedItemIDs.formIntersection(visible)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { !app.pendingDeleteIDs.isEmpty }, set: { if !$0 { app.pendingDeleteIDs = [] } })
        ) {
            Button("Delete", role: .destructive) {
                for id in app.pendingDeleteIDs { store.deleteItem(id) }
                app.selectedItemIDs.subtract(app.pendingDeleteIDs)
                app.pendingDeleteIDs = []
            }
            Button("Mark as Dropped Instead") {
                ItemActions(store: store, app: app).markDropped(app.pendingDeleteIDs)
                app.pendingDeleteIDs = []
            }
        } message: {
            Text("Deleting removes items and their activity history permanently.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var deleteTitle: String {
        let ids = app.pendingDeleteIDs
        if ids.count == 1, let item = store.item(ids.first) { return "Delete “\(item.title)”?" }
        return "Delete \(ids.count) items?"
    }

    static let inspectorWidth: CGFloat = 360
    /// Approximate minimum width of the split view columns without the inspector.
    private static let columnsMinWidth: CGFloat = 960

    /// SwiftUI doesn't widen the window for the inspector, so the panel would be pushed past the edge. Grow it like Xcode does.
    private static func growWindowForInspector() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let screen = window.screen else { return }
        let needed = columnsMinWidth + inspectorWidth
        var frame = window.frame
        guard frame.width < needed else { return }
        let visible = screen.visibleFrame
        frame.size.width = min(needed, visible.width)
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        window.setFrame(frame, display: true, animate: true)
    }
}

struct AssistantToolbar: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content.toolbar {
            ToolbarItem {
                Toggle(isOn: $app.showAgent) {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help("Show the assistant (⌘J)")
            }
        }
    }
}
