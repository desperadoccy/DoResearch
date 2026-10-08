import AppKit
import SwiftUI

@main
struct DoResearchApp: App {
    @State private var store: Store
    @State private var appState = AppState()
    @State private var agent: AgentSession

    init() {
        // Lets the bare SwiftPM binary behave like a normal app (dock icon, focus) when run outside the bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        let store = Store()
        _store = State(initialValue: store)
        _agent = State(initialValue: AgentSession(store: store))
    }

    var body: some Scene {
        WindowGroup("DoResearch", id: "main") {
            ContentView()
                .environment(store)
                .environment(appState)
                .environment(agent)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Item") { appState.requestNewItem() }
                    .keyboardShortcut("n")
                Button("New Project…") { appState.showingNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Duplicate") {
                    ItemActions(store: store, app: appState).duplicate(appState.selectedItemIDs)
                }
                .keyboardShortcut("d")
                .disabled(appState.selectedItemIDs.isEmpty)
            }
            CommandMenu("Go") {
                Button("Today") { appState.selection = .today }.keyboardShortcut("1")
                Button("Inbox") { appState.selection = .inbox }.keyboardShortcut("2")
                Button("Upcoming") { appState.selection = .upcoming }.keyboardShortcut("3")
                Button("Review") { appState.selection = .review }.keyboardShortcut("4")
                Divider()
                Button("Coding") { appState.selection = .kind(.coding) }.keyboardShortcut("5")
                Button("Experiments") { appState.selection = .kind(.experiment) }.keyboardShortcut("6")
                Button("Writing") { appState.selection = .kind(.writing) }.keyboardShortcut("7")
            }
            CommandGroup(after: .sidebar) {
                Button(appState.showAgent ? "Hide Assistant" : "Show Assistant") { appState.showAgent.toggle() }
                    .keyboardShortcut("j")
            }
        }

        Settings {
            SettingsView()
                .environment(agent)
        }
    }
}

@Observable
@MainActor
final class AppState {
    var selection: SidebarSelection? = .today
    var selectedItemIDs: Set<String> = []
    /// The single selected item, or nil when nothing or several items are selected.
    var selectedItemID: String? {
        get { selectedItemIDs.count == 1 ? selectedItemIDs.first : nil }
        set { selectedItemIDs = newValue.map { [$0] } ?? [] }
    }
    /// Items cut with ⌘X; the next paste moves them as long as the clipboard still holds them.
    var cutIDs: Set<String> = []
    /// Items awaiting delete confirmation.
    var pendingDeleteIDs: Set<String> = []
    var showAgent = false
    var showingNewProject = false
    var search = ""
    /// Incremented to ask the list to focus its quick-add field.
    var newItemRequest = 0

    func requestNewItem() {
        if selection == .review || selection == .logbook || selection == nil { selection = .inbox }
        newItemRequest += 1
    }
}
