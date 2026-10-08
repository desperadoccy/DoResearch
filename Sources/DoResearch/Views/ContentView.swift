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
            // Keep the selection only if the item is still visible in the new list.
            if let id = app.selectedItemID, let new, new != .review,
               store.items(for: new).contains(where: { $0.id == id }) {
                return
            }
            app.selectedItemID = nil
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
