import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Clipboard, duplicate, and drag-and-drop behavior shared by the list, board, sidebar, menus, and context menus.
@MainActor
struct ItemActions {
    let store: Store
    let app: AppState

    static var sortOrder: SortOrder {
        SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .manual
    }

    /// Whether drops and pastes in `selection` should set a position (only when the list shows manual order).
    static func usesManualOrder(_ selection: SidebarSelection) -> Bool {
        sortOrder == .manual && selection.supportsManualOrder
    }

    /// The given items in the order the current list shows them.
    func ordered(_ ids: Set<String>) -> [Item] {
        let visible = app.selection.map { store.items(for: $0, order: Self.sortOrder) } ?? []
        let inList = visible.filter { ids.contains($0.id) }
        let rest = store.items.filter { ids.contains($0.id) && !inList.map(\.id).contains($0.id) }.sorted(by: Store.manualOrder)
        return inList + rest
    }

    // MARK: Clipboard

    /// Copies to the clipboard. With `write: false` the caller (a SwiftUI copy command) writes the returned providers.
    @discardableResult
    func copy(_ ids: Set<String>, write: Bool = true) -> [NSItemProvider] {
        let items = ordered(ids)
        guard !items.isEmpty else { return [] }
        cancelCut()
        if write { Clipboard.write(items) }
        return Clipboard.providers(items)
    }

    /// Cut doesn't remove anything: the items are dimmed and the next paste in DoResearch moves them.
    @discardableResult
    func cut(_ ids: Set<String>, write: Bool = true) -> [NSItemProvider] {
        let items = ordered(ids)
        guard !items.isEmpty else { return [] }
        if write { Clipboard.write(items) }
        app.cutIDs = Set(items.map(\.id))
        return Clipboard.providers(items)
    }

    func cancelCut() {
        app.cutIDs = []
    }

    /// True while the clipboard still holds exactly what was last cut.
    var hasPendingCut: Bool {
        !app.cutIDs.isEmpty && Clipboard.itemIDs == app.cutIDs
    }

    /// Pastes into the current list, after the selection (or at the top). Moves cut items, copies everything else.
    func paste() {
        guard let selection = app.selection, selection != .review else { return }
        let incoming = Clipboard.read()
        guard !incoming.isEmpty else { return }
        let moving = hasPendingCut
        let visible = Self.usesManualOrder(selection) ? store.items(for: selection, order: .manual) : nil
        let incomingIDs = moving ? Set(incoming.map(\.id)) : []
        let anchor = visible.flatMap { list -> String? in
            let start = list.lastIndex { app.selectedItemIDs.contains($0.id) }.map { $0 + 1 } ?? 0
            return list[start...].first { !incomingIDs.contains($0.id) }?.id
        }
        let placed = store.place(incoming, copy: !moving, placement: selection.placement, before: anchor, within: visible)
        if moving { cancelCut() }
        app.selectedItemIDs = Set(placed)
    }

    func duplicate(_ ids: Set<String>) {
        let created = store.duplicate(ordered(ids).map(\.id))
        if !created.isEmpty { app.selectedItemIDs = Set(created) }
    }

    func markDropped(_ ids: Set<String>) {
        for id in ids { store.setStatus(.dropped, for: id) }
    }

    // MARK: Drag and drop

    /// What a drag starting on `item` carries: the whole selection if the item is part of it.
    func dragPayload(for item: Item, in visible: [Item]) -> ItemTransfer {
        guard app.selectedItemIDs.contains(item.id), app.selectedItemIDs.count > 1 else { return ItemTransfer(items: [item]) }
        let inList = visible.filter { app.selectedItemIDs.contains($0.id) }
        return ItemTransfer(items: inList.isEmpty ? [item] : inList)
    }

    static let dropTypes: [UTType] = [.doResearchItems, .utf8PlainText, .plainText]

    /// Handles a drop. Must be called synchronously from the drop callback: Option is read right away
    /// (it's usually released before the payload finishes loading), then the items load asynchronously.
    /// With `list`, the items are positioned at `insertAt` in it (index as displayed, counting dragged rows).
    @discardableResult
    func drop(_ providers: [NSItemProvider], placement: Placement, insertAt: Int? = nil,
              in list: [Item]? = nil, select: Bool = true) -> Bool {
        guard !providers.isEmpty else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            let incoming = await Self.loadItems(providers)
            guard !incoming.isEmpty else { return }
            var anchor: String?
            if let list, let insertAt {
                let incomingIDs = Set(incoming.map(\.id))
                anchor = list[min(max(insertAt, 0), list.count)...].first { !incomingIDs.contains($0.id) }?.id
            }
            let placed = store.place(incoming, copy: copy, placement: placement, before: anchor, within: list)
            if select { app.selectedItemIDs = Set(placed) }
        }
        return true
    }

    private static func loadItems(_ providers: [NSItemProvider]) async -> [Item] {
        var items: [Item] = []
        for provider in providers {
            let transfer = await withCheckedContinuation { (done: CheckedContinuation<ItemTransfer?, Never>) in
                _ = provider.loadTransferable(type: ItemTransfer.self) { done.resume(returning: try? $0.get()) }
            }
            items += transfer?.items ?? []
        }
        return items
    }
}

/// Wires Edit ▸ Cut/Copy/Paste/Delete and Escape to the focused item list or board.
struct ItemCommands: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        let actions = ItemActions(store: store, app: app)
        let hasSelection = !app.selectedItemIDs.isEmpty
        content
            .onCopyCommand(perform: hasSelection ? { actions.copy(app.selectedItemIDs, write: false) } : nil)
            .onCutCommand(perform: hasSelection ? { actions.cut(app.selectedItemIDs, write: false) } : nil)
            .onPasteCommand(of: ItemActions.dropTypes) { _ in actions.paste() }
            .onDeleteCommand(perform: hasSelection ? { actions.markDropped(app.selectedItemIDs) } : nil)
            .onExitCommand { actions.cancelCut() }
    }
}

// MARK: - Context menu

struct ItemContextMenu: View {
    let ids: Set<String>
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    private var items: [Item] { store.items.filter { ids.contains($0.id) } }

    var body: some View {
        let actions = ItemActions(store: store, app: app)
        let items = items
        if items.isEmpty {
            Button("Paste") { actions.paste() }
                .disabled(!Clipboard.hasContent)
        } else {
            let sharedKind = Set(items.map(\.kind)).count == 1 ? items.first?.kind : nil
            Menu("Status") {
                ForEach(ItemStatus.allCases) { status in
                    Button(sharedKind.map { status.label(for: $0) } ?? status.genericLabel) {
                        for item in items { store.setStatus(status, for: item.id) }
                    }
                }
            }
            Menu("Kind") {
                ForEach(ItemKind.allCases) { kind in
                    Button(kind.label) { mutate(items) { $0.kind = kind } }
                }
            }
            Menu("Project") {
                Button("None") { mutate(items) { $0.projectID = nil } }
                Divider()
                ForEach(ProjectType.allCases) { type in
                    let group = store.activeProjects.filter { $0.type == type }
                    if !group.isEmpty {
                        Section(type.label) {
                            ForEach(group) { p in
                                Button(p.name) {
                                    mutate(items) {
                                        $0.projectID = p.id
                                        store.fitKindToProject(&$0, explicitKind: nil)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if items.count == 1, let item = items.first, item.tracksProgress {
                Button("Progress +1 (\(item.progressLabel))") { store.stepProgress(item.id, by: 1) }
                Button("Progress −1") { store.stepProgress(item.id, by: -1) }
                    .disabled(item.progressCurrent == 0)
            }
            let allToday = items.allSatisfy(\.flaggedToday)
            Button(allToday ? "Remove from Today" : "Add to Today") {
                mutate(items) { Placement(today: !allToday).apply(to: &$0) }
            }
            Divider()
            Button("Cut") { actions.cut(ids) }
            Button("Copy") { actions.copy(ids) }
            Button("Paste") {
                app.selectedItemIDs = ids
                actions.paste()
            }
            .disabled(!Clipboard.hasContent)
            Button("Duplicate") { actions.duplicate(ids) }
            Divider()
            Button(items.count == 1 ? "Ask Assistant About This" : "Ask Assistant About These") {
                app.selectedItemIDs = ids
                app.showAgent = true
            }
            Divider()
            Button(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", role: .destructive) {
                app.pendingDeleteIDs = ids
            }
        }
    }

    private func mutate(_ items: [Item], _ change: (inout Item) -> Void) {
        for item in items {
            guard var copy = store.item(item.id) else { continue }
            change(&copy)
            store.updateItem(copy)
        }
    }
}

// MARK: - Multiple selection

struct MultiSelectionView: View {
    let ids: Set<String>
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    var body: some View {
        let items = ItemActions(store: store, app: app).ordered(ids)
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("\(items.count) Items Selected")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.prefix(8)) { item in
                    Label {
                        Text(item.title).lineLimit(2)
                    } icon: {
                        Image(systemName: item.kind.symbol).foregroundStyle(item.kind.color)
                    }
                }
                if items.count > 8 {
                    Text("and \(items.count - 8) more").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            HStack {
                Button("Mark Done") {
                    for item in items { store.setStatus(.done, for: item.id) }
                }
                Menu("Actions") {
                    ItemContextMenu(ids: ids)
                }
                .fixedSize()
            }
            Text("Drag them onto a list or project in the sidebar to move them (hold ⌥ to copy), or use ⌘X, ⌘C, ⌘V and ⌘D.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DragPreview: View {
    let transfer: ItemTransfer

    var body: some View {
        HStack(spacing: 6) {
            if let first = transfer.items.first {
                Image(systemName: first.kind.symbol).foregroundStyle(first.kind.color)
                Text(first.title).lineLimit(1)
            }
            if transfer.items.count > 1 {
                Text("\(transfer.items.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .background(Color.red, in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
