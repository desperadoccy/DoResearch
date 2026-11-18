import SwiftUI

/// The checklist as a directed graph: drag a step to move it, drag from its right-hand handle onto another step to
/// link them (drag again to undo), and click a link's badge to make it conditional ("if it went well / badly") or
/// remove it. A link back to an earlier step, or onto the step itself, is a loop drawn as a dashed arc below.
struct ChecklistGraphView: View {
    let item: Item

    @Environment(Store.self) private var store
    /// The step being moved and where it is right now (saved when the drag ends).
    @State private var moving: (id: String, center: CGPoint)?
    /// A link being drawn from a step's handle to the pointer.
    @State private var linking: (from: String, point: CGPoint, target: String?)?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var hoveredEdge: String?
    @State private var editingEdge: String?

    static let nodeSize = CGSize(width: 180, height: 48)
    static let columnGap: CGFloat = 70
    static let rowGap: CGFloat = 22
    static let margin: CGFloat = 24

    var body: some View {
        let centers = currentCenters()
        let size = contentSize(centers)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: size.width, height: size.height)
                edges(centers)
                if let linking, let from = centers[linking.from] {
                    // Orange: drop removes the existing link. Purple: drop adds a loop back to an earlier step.
                    let existing = linking.target.map { t in item.checklist.first { $0.id == t }?.after.contains(linking.from) == true } ?? false
                    let loop = linking.target.map { store.wouldLoop(from: linking.from, to: $0, in: item.id) } ?? false
                    EdgeShape(from: outPort(from), to: linking.point)
                        .stroke(existing ? Color.orange : loop ? Color.purple : Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
                ForEach(item.checklist) { entry in
                    if let c = centers[entry.id] { nodeView(entry, center: c, centers: centers) }
                }
                if moving == nil, linking == nil { edgeButtons(centers) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: "graph")
        }
        .frame(height: min(max(size.height, 160), 420))
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: placeUnplaced)
        .onChange(of: item.checklist.map(\.id)) { placeUnplaced() }
    }

    // MARK: Nodes

    /// Steps with an "if it went well / badly" link leaving them get two result buttons instead of a checkbox.
    private func hasBranches(_ entry: ChecklistEntry) -> Bool {
        item.checklist.contains { e in e.links.contains { $0.from == entry.id && $0.condition != .always } }
    }

    private func setResult(_ entry: ChecklistEntry, done: Bool, failed: Bool) {
        var e = entry
        e.done = done
        e.failed = done && failed
        store.updateChecklistEntry(e)
    }

    private func nodeView(_ entry: ChecklistEntry, center: CGPoint, centers: [String: CGPoint]) -> some View {
        let blocked = !entry.done && item.isBlocked(entry)
        let skipped = item.isSkipped(entry)
        let bad = entry.done && entry.failed
        let isTarget = linking?.target == entry.id
        return HStack(spacing: 6) {
            if hasBranches(entry) {
                resultButton(entry, failed: false)
                resultButton(entry, failed: true)
            } else {
                Button {
                    setResult(entry, done: !entry.done, failed: false)
                } label: {
                    Image(systemName: bad ? "xmark.circle.fill" : entry.done ? "checkmark.circle.fill"
                          : blocked ? "lock.circle" : skipped ? "minus.circle" : "circle")
                        .foregroundStyle(bad ? Color.red : entry.done ? Color.green : .secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help(blocked ? "Waiting on earlier steps" : skipped ? "Not on the path taken"
                      : entry.done ? "Mark as not done" : "Mark as done")
            }

            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .font(.callout)
                .lineLimit(2)
                .strikethrough(entry.done)
                .foregroundStyle(entry.done || blocked || skipped ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .padding(4)
                .contentShape(Rectangle())
                .help("Drag onto another step to link to it. Drag onto an earlier step, or back onto this one, for a loop.")
                .gesture(linkGesture(from: entry.id, centers: centers))
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTarget ? Color.accentColor
                              : bad ? Color.red.opacity(0.5) : entry.done ? Color.green.opacity(0.5) : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: isTarget ? 2 : 1, dash: skipped ? [4, 3] : []))
        )
        .opacity(skipped ? 0.55 : 1)
        .shadow(color: .black.opacity(moving?.id == entry.id ? 0.18 : 0.06), radius: moving?.id == entry.id ? 6 : 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .position(center)
        .zIndex(moving?.id == entry.id ? 1 : 0)
        .gesture(moveGesture(entry.id, centers: centers))
        .onTapGesture(count: 2) { renameText = entry.title; renaming = entry.id }
        .popover(isPresented: Binding(get: { renaming == entry.id }, set: { if !$0 { commitRename() } })) {
            TextField("Step", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .padding()
                .onSubmit(commitRename)
        }
        .contextMenu { nodeMenu(entry) }
    }

    /// ✓ "went well" or ✗ "went badly". Clicking the current result again reopens the step.
    private func resultButton(_ entry: ChecklistEntry, failed: Bool) -> some View {
        let on = entry.done && entry.failed == failed
        return Button {
            setResult(entry, done: !on, failed: failed)
        } label: {
            Image(systemName: failed ? (on ? "xmark.circle.fill" : "xmark.circle") : (on ? "checkmark.circle.fill" : "checkmark.circle"))
                .foregroundStyle(on ? (failed ? Color.red : .green) : Color.secondary)
                .font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .help(on ? "Mark as not done" : failed ? "Done — it went badly" : "Done — it went well")
    }

    @ViewBuilder
    private func nodeMenu(_ entry: ChecklistEntry) -> some View {
        Button("Rename…") { renameText = entry.title; renaming = entry.id }
        Button("Done — Went Well") { setResult(entry, done: true, failed: false) }
        Button("Done — Went Badly") { setResult(entry, done: true, failed: true) }
        if entry.done { Button("Mark as Not Done") { setResult(entry, done: false, failed: false) } }
        let before = entry.after.compactMap { id in item.checklist.first { $0.id == id } }
        let next = item.checklist.filter { $0.after.contains(entry.id) }
        if !before.isEmpty || !next.isEmpty {
            Divider()
            ForEach(before) { p in
                Button("Remove Link from “\(p.title)”") { store.unlinkChecklist(from: p.id, to: entry.id, in: item.id) }
            }
            ForEach(next) { n in
                Button("Remove Link to “\(n.title)”") { store.unlinkChecklist(from: entry.id, to: n.id, in: item.id) }
            }
        }
        Divider()
        Button("Delete Step", role: .destructive) { store.removeChecklistEntry(entry) }
    }

    private func commitRename() {
        defer { renaming = nil }
        guard let id = renaming, var e = item.checklist.first(where: { $0.id == id }) else { return }
        let t = renameText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != e.title else { return }
        e.title = t
        store.updateChecklistEntry(e)
    }

    // MARK: Edges

    private struct Edge: Identifiable {
        let link: ChecklistLink
        let to: ChecklistEntry
        let shape: EdgeShape
        var id: String { link.from + ">" + to.id }
    }

    private func allEdges(_ centers: [String: CGPoint]) -> [Edge] {
        item.checklist.flatMap { entry in
            entry.links.compactMap { l -> Edge? in
                guard let a = centers[l.from], let b = centers[entry.id] else { return nil }
                return Edge(link: l, to: entry, shape: l.loop ? loopShape(a, b) : EdgeShape(from: outPort(a), to: inPort(b), arrow: true))
            }
        }
    }

    private func strokeColor(_ l: ChecklistLink) -> Color {
        l.condition == .always ? (l.loop ? .purple : .secondary) : l.condition.tint
    }

    private func notTaken(_ l: ChecklistLink) -> Bool {
        guard let source = item.checklist.first(where: { $0.id == l.from }) else { return false }
        return source.done && !ChecklistEntry.taken(l, done: source.done, failed: source.failed)
    }

    private func edges(_ centers: [String: CGPoint]) -> some View {
        ForEach(allEdges(centers)) { e in
            // Once the source is done, a branch it didn't take fades out.
            let hot = hoveredEdge == e.id || editingEdge == e.id
            e.shape
                .stroke(strokeColor(e.link).opacity(notTaken(e.link) ? 0.25 : hot ? 1 : 0.75),
                        style: StrokeStyle(lineWidth: hot ? 2.5 : 1.5, lineCap: .round, dash: e.link.loop ? [5, 4] : []))
        }
    }

    /// A badge at each link's midpoint, drawn above the steps: click to choose when the link is followed, or remove it.
    private func edgeButtons(_ centers: [String: CGPoint]) -> some View {
        ForEach(allEdges(centers)) { e in
            let title = item.checklist.first { $0.id == e.link.from }?.title ?? ""
            Button { editingEdge = e.id } label: {
                LinkBadge(link: e.link, hot: hoveredEdge == e.id || editingEdge == e.id, faded: notTaken(e.link))
            }
            .buttonStyle(.plain)
            .onHover { hoveredEdge = $0 ? e.id : (hoveredEdge == e.id ? nil : hoveredEdge) }
            .help("\(e.link.loop ? "Loop" : "Link") “\(title)” → “\(e.to.title)”: \(e.link.condition.label.lowercased()). Click to change or remove.")
            .popover(isPresented: Binding(get: { editingEdge == e.id }, set: { if !$0, editingEdge == e.id { editingEdge = nil } }),
                     arrowEdge: .bottom) {
                LinkEditor(fromTitle: title, toTitle: e.to.title, link: e.link,
                           onCondition: { store.setLinkCondition(from: e.link.from, to: e.to.id, in: item.id, $0) },
                           onRemove: {
                               editingEdge = nil
                               hoveredEdge = nil
                               store.unlinkChecklist(from: e.link.from, to: e.to.id, in: item.id)
                           })
            }
            .position(e.shape.midpoint)
            .zIndex(2)
        }
    }

    // MARK: Gestures

    private func moveGesture(_ id: String, centers: [String: CGPoint]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("graph"))
            .onChanged { v in
                guard let start = item.checklist.first(where: { $0.id == id }).flatMap(storedCenter) ?? centers[id] else { return }
                moving = (id, clamp(CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height)))
            }
            .onEnded { _ in
                if let m = moving { store.moveChecklistEntry(m.id, in: item.id, to: m.center) }
                moving = nil
            }
    }

    /// Where a link drag would land: another step, or this one if the pointer left it and came back (a self-loop).
    private func linkTarget(_ v: DragGesture.Value, from id: String, _ centers: [String: CGPoint]) -> String? {
        guard let target = node(at: v.location, centers) else { return nil }
        if target == id, hypot(v.translation.width, v.translation.height) < 60 { return nil }
        return target
    }

    private func linkGesture(from id: String, centers: [String: CGPoint]) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
            .onChanged { v in linking = (id, v.location, linkTarget(v, from: id, centers)) }
            .onEnded { v in
                if let target = linkTarget(v, from: id, centers) {
                    if item.checklist.first(where: { $0.id == target })?.after.contains(id) == true {
                        store.unlinkChecklist(from: id, to: target, in: item.id)
                    } else {
                        store.linkChecklist(from: id, to: target, in: item.id)
                    }
                }
                linking = nil
            }
    }

    // MARK: Geometry

    private func storedCenter(_ e: ChecklistEntry) -> CGPoint? {
        guard let x = e.x, let y = e.y else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Saved positions, the live drag, and a depth-based spot for any step not yet placed.
    private func currentCenters() -> [String: CGPoint] {
        var out = Self.layout(item, keepingPlaced: true)
        if let moving { out[moving.id] = moving.center }
        return out
    }

    private func contentSize(_ centers: [String: CGPoint]) -> CGSize {
        let maxX = centers.values.map(\.x).max() ?? 0, maxY = centers.values.map(\.y).max() ?? 0
        // Leave room to drag steps outward; the area grows as they move.
        return CGSize(width: max(maxX + Self.nodeSize.width / 2 + 160, 520),
                      height: max(maxY + Self.nodeSize.height / 2 + Self.margin + (hasLoops ? Self.loopDepth + 20 : 0), 120))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(p.x, Self.nodeSize.width / 2 + 4), y: max(p.y, Self.nodeSize.height / 2 + 4))
    }

    private func node(at p: CGPoint, _ centers: [String: CGPoint]) -> String? {
        item.checklist.last { e in
            guard let c = centers[e.id] else { return false }
            return abs(p.x - c.x) <= Self.nodeSize.width / 2 && abs(p.y - c.y) <= Self.nodeSize.height / 2
        }?.id
    }

    private var hasLoops: Bool { item.checklist.contains { $0.links.contains(where: \.loop) } }

    static let loopDepth: CGFloat = 46

    /// A dashed arc under the steps, from the bottom of the later step back to the bottom of the earlier one.
    private func loopShape(_ a: CGPoint, _ b: CGPoint) -> EdgeShape {
        let inset = Self.nodeSize.width / 2 - 30
        let from = CGPoint(x: a.x + inset, y: a.y + Self.nodeSize.height / 2)
        let to = CGPoint(x: b.x - inset, y: b.y + Self.nodeSize.height / 2)
        let bottom = max(from.y, to.y) + Self.loopDepth + abs(from.x - to.x) * 0.08
        return EdgeShape(from: from, to: to, control1: CGPoint(x: from.x, y: bottom), control2: CGPoint(x: to.x, y: bottom), arrow: true)
    }

    private func outPort(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x + Self.nodeSize.width / 2, y: c.y) }
    private func inPort(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x - Self.nodeSize.width / 2, y: c.y) }

    private func placeUnplaced() {
        let missing = item.checklist.filter { $0.x == nil || $0.y == nil }
        guard !missing.isEmpty else { return }
        let layout = Self.layout(item, keepingPlaced: true)
        store.placeChecklistEntries(Dictionary(uniqueKeysWithValues: missing.compactMap { e in layout[e.id].map { (e.id, $0) } }),
                                    in: item.id)
    }

    /// Columns by dependency depth (a step sits one column right of its deepest prerequisite), rows in checklist order.
    /// With `keepingPlaced`, saved positions win and new steps go below whatever already occupies their column.
    static func layout(_ item: Item, keepingPlaced: Bool) -> [String: CGPoint] {
        var depth: [String: Int] = [:]
        for e in item.checklistInGraphOrder {
            depth[e.id] = (e.prerequisites.compactMap { depth[$0.from] }.max() ?? -1) + 1
        }
        let colWidth = nodeSize.width + columnGap, rowHeight = nodeSize.height + rowGap
        func columnX(_ d: Int) -> CGFloat { margin + nodeSize.width / 2 + CGFloat(d) * colWidth }
        var out: [String: CGPoint] = [:]
        if keepingPlaced {
            for e in item.checklist { if let x = e.x, let y = e.y { out[e.id] = CGPoint(x: x, y: y) } }
        }
        for e in item.checklistInGraphOrder where out[e.id] == nil {
            let x = columnX(depth[e.id] ?? 0)
            let below = out.values.filter { abs($0.x - x) < nodeSize.width }.map(\.y).max()
            out[e.id] = CGPoint(x: x, y: below.map { $0 + rowHeight } ?? margin + nodeSize.height / 2)
        }
        return out
    }
}

/// A cubic curve between two points with an optional arrowhead at the end. By default a horizontal S-curve.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var arrow = false

    init(from: CGPoint, to: CGPoint, arrow: Bool = false) {
        let dx = max(abs(to.x - from.x) / 2, 40)
        self.init(from: from, to: to, control1: CGPoint(x: from.x + dx, y: from.y), control2: CGPoint(x: to.x - dx, y: to.y), arrow: arrow)
    }

    init(from: CGPoint, to: CGPoint, control1: CGPoint, control2: CGPoint, arrow: Bool) {
        self.from = from
        self.to = to
        self.control1 = control1
        self.control2 = control2
        self.arrow = arrow
    }

    /// The point at t = 0.5.
    var midpoint: CGPoint {
        CGPoint(x: (from.x + 3 * control1.x + 3 * control2.x + to.x) / 8, y: (from.y + 3 * control1.y + 3 * control2.y + to.y) / 8)
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addCurve(to: to, control1: control1, control2: control2)
        if arrow {
            let angle = atan2(to.y - control2.y, to.x - control2.x), len: CGFloat = 8, spread: CGFloat = .pi / 7
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread)))
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread)))
        }
        return p
    }
}
