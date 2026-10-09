import AppKit
import SwiftUI

enum ListLayout: String, CaseIterable {
    case list, board
}

struct ItemListView: View {
    let selection: SidebarSelection

    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @AppStorage("listLayout") private var layout: ListLayout = .list
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .manual
    @State private var newTitle = ""
    @State private var showDone = true
    @FocusState private var quickAddFocused: Bool

    private var supportsBoard: Bool {
        switch selection {
        case .kind, .project, .all: true
        default: false
        }
    }

    var body: some View {
        @Bindable var app = app
        let items = store.items(for: selection, search: app.search, order: sortOrder)
        let manual = sortOrder == .manual && selection.supportsManualOrder

        VStack(spacing: 0) {
            if case .project(let id) = selection, let project = store.project(id) {
                ProjectHeader(project: project)
                Divider()
            }
            quickAdd
            Divider()
            if supportsBoard && layout == .board {
                BoardView(items: items, kind: kindContext, listPlacement: selection.placement, manual: manual)
            } else {
                List(selection: $app.selectedItemIDs) {
                    ForEach(sections(items), id: \.title) { section in
                        Section {
                            if let placement = section.placement {
                                rows(section, visible: items)
                                    .onInsert(of: ItemActions.dropTypes) { offset, providers in
                                        actions.drop(providers, placement: selection.placement.merged(with: placement),
                                                     insertAt: offset, in: manual ? section.items : nil)
                                    }
                            } else {
                                rows(section, visible: items)
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Text("\(section.items.count)").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: String.self) { ids in
                    ItemContextMenu(ids: ids)
                }
                .modifier(ItemCommands())
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: Text(emptyMessage))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.background)
                            .onDrop(of: ItemActions.dropTypes, isTargeted: nil) { providers in
                                selection.acceptsDrops && actions.drop(providers, placement: selection.placement)
                            }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle(items))
        .toolbar {
            if supportsBoard {
                ToolbarItem {
                    Picker("Layout", selection: $layout) {
                        Label("List", systemImage: "list.bullet").tag(ListLayout.list)
                        Label("Board", systemImage: "rectangle.split.3x1").tag(ListLayout.board)
                    }
                    .pickerStyle(.segmented)
                    .help("Switch between list and board")
                }
            }
            if selection.supportsManualOrder {
                ToolbarItem {
                    Menu {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help(sortOrder == .manual ? "Sorted manually: drag items to rearrange" : "Sorted by \(sortOrder.label.lowercased())")
                }
            }
            ToolbarItem {
                Toggle(isOn: $showDone) {
                    Label("Show Completed", systemImage: "checkmark.circle")
                }
                .help(showDone ? "Hide completed items" : "Show completed items")
            }
        }
        .onChange(of: app.newItemRequest) { quickAddFocused = true }
    }

    private var actions: ItemActions { ItemActions(store: store, app: app) }

    private func rows(_ section: ItemSection, visible: [Item]) -> some DynamicViewContent {
        let actions = actions
        let cutActive = actions.hasPendingCut
        return ForEach(section.items) { item in
            let payload = actions.dragPayload(for: item, in: visible)
            ItemRow(item: item, showProject: !isProjectView)
                .opacity(cutActive && app.cutIDs.contains(item.id) ? 0.45 : 1)
                .tag(item.id)
                .draggable(payload) { DragPreview(transfer: payload) }
        }
    }

    // MARK: Quick add

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.tint)
                .imageScale(.large)
            TextField(quickAddPrompt, text: $newTitle)
                .textFieldStyle(.plain)
                .focused($quickAddFocused)
                .onSubmit(addItem)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var quickAddPrompt: String {
        switch selection {
        case .kind(let k): "New \(k.label.lowercased()) item"
        case .project(let id): "New item in \(store.project(id)?.name ?? "project")"
        case .today: "New item for today"
        default: "New item"
        }
    }

    private func addItem() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var draft = Item(id: "", title: title)
        switch selection {
        case .kind(let k): draft.kind = k
        case .project(let id):
            draft.projectID = id
            draft.kind = store.project(id)?.type.defaultKind ?? .task
        case .today: draft.flaggedToday = true
        case .inbox: draft.status = .inbox
        default: break
        }
        let created = store.createItem(draft)
        if sortOrder == .manual, selection.supportsManualOrder {
            // New items go to the top of the list they were typed into.
            let list = store.items(for: selection, order: .manual)
            store.reorder([created.id], before: list.first { $0.id != created.id }?.id, within: list)
        }
        app.selectedItemID = created.id
        newTitle = ""
    }

    // MARK: Sections

    struct ItemSection {
        let title: String
        let items: [Item]
        /// What an item dropped into this section becomes; nil for date-ordered sections that don't accept drops.
        var placement: Placement? = nil
    }

    private var isProjectView: Bool { if case .project = selection { true } else { false } }

    private var kindContext: ItemKind? { if case .kind(let k) = selection { k } else { nil } }

    private func sections(_ items: [Item]) -> [ItemSection] {
        let visible = showDone ? items : items.filter { $0.status.isOpen }
        switch selection {
        case .today:
            let focus = visible.filter { $0.flaggedToday || $0.isDueTodayOrEarlier }
            let rest = visible.filter { !($0.flaggedToday || $0.isDueTodayOrEarlier) }
            return [ItemSection(title: "Today", items: focus, placement: Placement(today: true)),
                    ItemSection(title: "In Progress", items: rest, placement: Placement(status: .inProgress, today: false))]
                .filter { !$0.items.isEmpty }
        case .inbox:
            return [ItemSection(title: "Unprocessed", items: visible, placement: Placement(status: .inbox))]
        case .upcoming:
            return group(visible) { $0.dueDate.map { $0.formatted(.dateTime.weekday(.wide).month().day()) } ?? "" }
        case .logbook:
            return group(items) { ($0.completedAt ?? $0.updatedAt).formatted(.dateTime.month(.wide).day().year()) }
        default:
            let order: [ItemStatus] = [.inbox, .inProgress, .waiting, .blocked, .todo, .done]
            return order.compactMap { status in
                let matching = visible.filter { $0.status == status }
                guard !matching.isEmpty else { return nil }
                let title = kindContext.map { status.label(for: $0) } ?? status.genericLabel
                return ItemSection(title: title, items: matching, placement: Placement(status: status))
            }
        }
    }

    private func group(_ items: [Item], by key: (Item) -> String) -> [ItemSection] {
        var order: [String] = []
        var buckets: [String: [Item]] = [:]
        for item in items {
            let k = key(item)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(item)
        }
        return order.map { ItemSection(title: $0, items: buckets[$0]!) }
    }

    // MARK: Titles

    private var title: String {
        switch selection {
        case .today: "Today"
        case .inbox: "Inbox"
        case .upcoming: "Upcoming"
        case .all: "All Items"
        case .logbook: "Logbook"
        case .review: "Review"
        case .kind(let k): k.pluralLabel
        case .project(let id): store.project(id)?.name ?? "Project"
        }
    }

    private func subtitle(_ items: [Item]) -> String {
        let open = items.filter { $0.status.isOpen }.count
        return selection == .logbook ? "\(items.count) closed" : "\(open) open"
    }

    private var emptyTitle: String {
        switch selection {
        case .inbox: "Inbox Zero"
        case .today: "Nothing for Today"
        default: "No Items"
        }
    }

    private var emptySymbol: String {
        switch selection {
        case .inbox: "tray"
        case .today: "sun.max"
        case .kind(let k): k.symbol
        default: "square.stack"
        }
    }

    private var emptyMessage: String {
        switch selection {
        case .today: "Flag items for today, give them a due date, or start working on something."
        case .upcoming: "Items with a future due date appear here."
        case .logbook: "Completed and dropped items appear here."
        default: "Type above to add one, or ask the assistant (⌘J)."
        }
    }
}

// MARK: - Row

struct ItemRow: View {
    let item: Item
    var showProject = true
    @Environment(Store.self) private var store

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusButton(item: item)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if item.priority != .none {
                        Text(item.priority.marks)
                            .font(.callout.weight(.bold))
                            .foregroundStyle(item.priority == .high ? .red : .orange)
                    }
                    Text(item.title)
                        .strikethrough(item.status == .dropped)
                        .foregroundStyle(item.status.isOpen ? .primary : .secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    KindBadge(kind: item.kind)
                    if item.status != .todo && item.status != .done {
                        Text(item.statusLabel)
                            .font(.caption)
                            .foregroundStyle(item.status.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    detailLine
                    if showProject, let p = store.project(item.projectID) {
                        Label(p.name, systemImage: p.symbol)
                            .font(.caption)
                            .foregroundStyle(p.swiftColor)
                            .lineLimit(1)
                    }
                    if let due = item.dueDate {
                        Label(due.formatted(.relative(presentation: .named)), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(item.isOverdue ? .red : .secondary)
                    }
                    if item.flaggedToday {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var detailLine: some View {
        let progress = item.checklistProgress
        if progress.total > 0 {
            Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        switch item.kind {
        case .experiment where item.outcome != .pending:
            Label(item.outcome.label, systemImage: item.outcome.symbol)
                .font(.caption)
                .foregroundStyle(item.outcome.color)
        case .coding where !item.branch.isEmpty:
            Label(item.branch, systemImage: "arrow.triangle.branch")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }
}

struct StatusButton: View {
    let item: Item
    @Environment(Store.self) private var store

    var body: some View {
        Button {
            store.setStatus(item.status == .done ? .todo : .done, for: item.id)
        } label: {
            Image(systemName: item.status.symbol)
                .foregroundStyle(item.status.color)
                .imageScale(.large)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(item.status == .done ? "Mark as not done" : "Mark as done")
    }
}

struct KindBadge: View {
    let kind: ItemKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(kind.color.opacity(0.15), in: Capsule())
            .foregroundStyle(kind.color)
    }
}

// MARK: - Board

struct BoardView: View {
    let items: [Item]
    let kind: ItemKind?
    let listPlacement: Placement
    let manual: Bool
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @State private var targetedColumn: ItemStatus?
    @State private var targetedCard: String?
    @FocusState private var focused: Bool

    private var actions: ItemActions { ItemActions(store: store, app: app) }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns, id: \.self) { status in
                    column(status)
                }
            }
            .padding(12)
        }
        .background(.background.secondary)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .modifier(ItemCommands())
    }

    /// A Bool binding that is true while `state` equals `value`, for drop-target highlighting.
    private func target<T: Equatable>(_ state: Binding<T?>, _ value: T) -> Binding<Bool> {
        Binding(get: { state.wrappedValue == value },
                set: { state.wrappedValue = $0 ? value : (state.wrappedValue == value ? nil : state.wrappedValue) })
    }

    private var columns: [ItemStatus] {
        items.contains { $0.status == .inbox } ? [.inbox] + ItemStatus.boardColumns : ItemStatus.boardColumns
    }

    private func column(_ status: ItemStatus) -> some View {
        let cards = items.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: status.symbol).foregroundStyle(status.color)
                Text(kind.map { status.label(for: $0) } ?? status.genericLabel).font(.headline)
                Spacer()
                Text("\(cards.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { item in
                        card(item, column: cards, status: status)
                    }
                }
                .padding(2)
            }
        }
        .padding(10)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targetedColumn == status ? Color.accentColor : Color.primary.opacity(0.08),
                              lineWidth: targetedColumn == status ? 2 : 1)
        )
        // Dropping on the column (not on a card) appends to its end.
        .onDrop(of: ItemActions.dropTypes, isTargeted: target($targetedColumn, status)) { providers in
            actions.drop(providers, placement: listPlacement.merged(with: Placement(status: status)),
                         insertAt: cards.count, in: manual ? cards : nil)
        }
    }

    private func card(_ item: Item, column cards: [Item], status: ItemStatus) -> some View {
        let payload = actions.dragPayload(for: item, in: items)
        let selected = app.selectedItemIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.body).lineLimit(3)
            HStack(spacing: 6) {
                KindBadge(kind: item.kind)
                if let p = store.project(item.projectID) {
                    Image(systemName: p.symbol).foregroundStyle(p.swiftColor).font(.caption)
                }
                Spacer()
                if item.kind == .experiment, item.outcome != .pending {
                    Image(systemName: item.outcome.symbol).foregroundStyle(item.outcome.color).font(.caption)
                }
            }
            let progress = item.checklistProgress
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .controlSize(.small)
                    .tint(item.kind.color)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .top) {
            // Insertion marker: the dropped cards land above this one.
            if targetedCard == item.id {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -5.5)
            }
        }
        .opacity(actions.hasPendingCut && app.cutIDs.contains(item.id) ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            if NSEvent.modifierFlags.contains(.command) {
                if selected { app.selectedItemIDs.remove(item.id) } else { app.selectedItemIDs.insert(item.id) }
            } else {
                app.selectedItemID = item.id
            }
        }
        .draggable(payload) { DragPreview(transfer: payload) }
        .onDrop(of: ItemActions.dropTypes, isTargeted: target($targetedCard, item.id)) { providers in
            actions.drop(providers, placement: listPlacement.merged(with: Placement(status: status)),
                         insertAt: cards.firstIndex { $0.id == item.id }, in: manual ? cards : nil)
        }
        .contextMenu {
            ItemContextMenu(ids: selected ? app.selectedItemIDs : [item.id])
        }
    }
}
