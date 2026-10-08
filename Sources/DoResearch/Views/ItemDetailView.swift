import SwiftUI

struct ItemDetailView: View {
    let itemID: String

    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @State private var tagText = ""
    @State private var newChecklistTitle = ""
    @State private var newNote = ""
    @State private var confirmingDelete = false

    var body: some View {
        if let item = store.item(itemID) {
            form(item)
                .navigationTitle(item.title.isEmpty ? "Untitled" : item.title)
                .onAppear { tagText = item.tags.joined(separator: ", ") }
                .onDisappear { commitTags() }
                .toolbar {
                    ToolbarItem {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete item")
                    }
                }
                .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) {
                        app.selectedItemID = nil
                        store.deleteItem(itemID)
                    }
                    Button("Mark as Dropped Instead") { store.setStatus(.dropped, for: itemID) }
                } message: {
                    Text("Deleting removes the item and its activity history permanently.")
                }
        }
    }

    private func bind<T>(_ item: Item, _ kp: WritableKeyPath<Item, T>) -> Binding<T> {
        Binding(
            get: { (store.item(itemID) ?? item)[keyPath: kp] },
            set: { value in
                var copy = store.item(itemID) ?? item
                copy[keyPath: kp] = value
                store.updateItem(copy)
            }
        )
    }

    private func optionalDate(_ item: Item, _ kp: WritableKeyPath<Item, Date?>, default value: @escaping () -> Date) -> (Binding<Bool>, Binding<Date>) {
        let b = bind(item, kp)
        return (
            Binding(get: { b.wrappedValue != nil }, set: { b.wrappedValue = $0 ? value() : nil }),
            Binding(get: { b.wrappedValue ?? value() }, set: { b.wrappedValue = $0 })
        )
    }

    // MARK: Form

    private func form(_ item: Item) -> some View {
        VStack(spacing: 0) {
            header(item)
            Divider()
            fields(item)
        }
    }

    private func header(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: bind(item, \.title), prompt: Text("Title"), axis: .vertical)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
            HStack(spacing: 8) {
                KindBadge(kind: item.kind)
                Text(item.statusLabel).font(.caption).foregroundStyle(item.status.color)
                Spacer()
                Text("Updated \(item.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func fields(_ item: Item) -> some View {
        Form {
            Section("Details") {
                Picker("Kind", selection: bind(item, \.kind)) {
                    ForEach(ItemKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Picker("Status", selection: bind(item, \.status)) {
                    ForEach(ItemStatus.allCases) { Label($0.label(for: item.kind), systemImage: $0.symbol).tag($0) }
                }
                Picker("Priority", selection: bind(item, \.priority)) {
                    ForEach(Priority.allCases) { Text($0.label).tag($0) }
                }
                Picker("Project", selection: bind(item, \.projectID)) {
                    Text("None").tag(String?.none)
                    ForEach(store.projects) { p in
                        Label(p.name, systemImage: p.symbol).tag(Optional(p.id))
                    }
                }
                let due = optionalDate(item, \.dueDate) { Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400) }
                Toggle("Due date", isOn: due.0)
                if due.0.wrappedValue {
                    DatePicker("Due", selection: due.1, displayedComponents: .date)
                }
                Toggle("Show in Today", isOn: bind(item, \.flaggedToday))
                TextField("Tags", text: $tagText, prompt: Text("comma, separated"))
                    .onSubmit(commitTags)
            }

            switch item.kind {
            case .coding: codingSection(item)
            case .experiment: experimentSections(item)
            default: EmptyView()
            }

            checklistSection(item)

            Section("Notes") {
                LongField("", text: bind(item, \.notes), prompt: "Notes, links, context…", minLines: 3)
            }

            activitySection(item)
        }
        .formStyle(.grouped)
    }

    private func commitTags() {
        guard var item = store.item(itemID) else { return }
        let tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if tags != item.tags {
            item.tags = tags
            store.updateItem(item)
        }
    }

    // MARK: Coding

    @ViewBuilder
    private func codingSection(_ item: Item) -> some View {
        Section {
            TextField("Repository", text: bind(item, \.repo), prompt: Text("~/code/project or github.com/org/repo"))
            TextField("Branch", text: bind(item, \.branch), prompt: Text("feature/…"))
                .font(.body.monospaced())
            HStack {
                TextField("PR / Issue", text: bind(item, \.link), prompt: Text("https://…"))
                if let url = URL(string: item.link), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open link")
                }
            }
        } header: {
            Label("Code", systemImage: ItemKind.coding.symbol)
        }
    }

    // MARK: Experiment

    @ViewBuilder
    private func experimentSections(_ item: Item) -> some View {
        Section {
            LongField("Hypothesis", text: bind(item, \.hypothesis), prompt: "What do you expect, and why?")
            LongField("Setup", text: bind(item, \.setup), prompt: "Config, command, dataset, seed…", monospaced: true)
            TextField("Compute", text: bind(item, \.compute), prompt: Text("e.g. 4×A100 on cluster-a"))
            LabeledContent("Run") {
                HStack {
                    if let start = item.runStartedAt {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                        if let end = item.runEndedAt {
                            Text("→ \(end.formatted(date: .omitted, time: .shortened))")
                            Text("(\(Duration.seconds(end.timeIntervalSince(start)).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow))))")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not started").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.runStartedAt == nil || item.runEndedAt != nil {
                        Button("Start Run") {
                            var copy = item
                            copy.runStartedAt = Date()
                            copy.runEndedAt = nil
                            copy.status = .inProgress
                            store.updateItem(copy)
                        }
                    } else {
                        Button("End Run") {
                            var copy = item
                            copy.runEndedAt = Date()
                            copy.status = .waiting
                            store.updateItem(copy)
                        }
                    }
                }
            }
        } header: {
            Label("Experiment Design", systemImage: ItemKind.experiment.symbol)
        }

        Section {
            ForEach(item.metrics.indices, id: \.self) { i in
                HStack {
                    TextField("Metric", text: metricBinding(item, i, \.name), prompt: Text("metric"))
                        .labelsHidden()
                    TextField("Value", text: metricBinding(item, i, \.value), prompt: Text("value"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                    Button {
                        var copy = item
                        copy.metrics.remove(at: i)
                        store.updateItem(copy)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                var copy = item
                copy.metrics.append(Metric(name: "", value: ""))
                store.updateItem(copy)
            } label: {
                Label("Add Metric", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            LongField("Results", text: bind(item, \.results), prompt: "Observations, tables, plots, paths to logs…")
            Picker("Outcome", selection: bind(item, \.outcome)) {
                ForEach(ExperimentOutcome.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            LongField("Conclusion", text: bind(item, \.conclusion), prompt: "What did you learn? What's next?")
        } header: {
            Label("Results", systemImage: "chart.xyaxis.line")
        }
    }

    private func metricBinding(_ item: Item, _ index: Int, _ kp: WritableKeyPath<Metric, String>) -> Binding<String> {
        Binding(
            get: {
                let current = store.item(itemID) ?? item
                return current.metrics.indices.contains(index) ? current.metrics[index][keyPath: kp] : ""
            },
            set: { value in
                var copy = store.item(itemID) ?? item
                guard copy.metrics.indices.contains(index) else { return }
                copy.metrics[index][keyPath: kp] = value
                store.updateItem(copy)
            }
        )
    }

    // MARK: Checklist

    private func checklistSection(_ item: Item) -> some View {
        Section {
            ForEach(item.checklist) { entry in
                HStack {
                    Toggle(isOn: Binding(
                        get: { entry.done },
                        set: { var e = entry; e.done = $0; store.updateChecklistEntry(e) }
                    )) {
                        TextField("Step", text: Binding(
                            get: { entry.title },
                            set: { var e = entry; e.title = $0; store.updateChecklistEntry(e) }
                        ))
                        .textFieldStyle(.plain)
                        .strikethrough(entry.done)
                        .foregroundStyle(entry.done ? .secondary : .primary)
                    }
                    .toggleStyle(.checkbox)
                    Button {
                        store.removeChecklistEntry(entry)
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            TextField("Add step", text: $newChecklistTitle, prompt: Text("Add a step and press Return"))
                .onSubmit {
                    let t = newChecklistTitle.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    store.addChecklistEntry(to: itemID, title: t)
                    newChecklistTitle = ""
                }
        } header: {
            HStack {
                Text(item.kind == .coding ? "Implementation Steps" : "Checklist")
                Spacer()
                let p = item.checklistProgress
                if p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .frame(width: 80)
                        .controlSize(.small)
                    Text("\(p.done)/\(p.total)").monospacedDigit()
                }
            }
        }
    }

    // MARK: Activity

    private func activitySection(_ item: Item) -> some View {
        Section("Progress Log") {
            HStack {
                TextField("Log progress", text: $newNote, prompt: Text("What happened? (Return to log)"))
                    .onSubmit(addNote)
                Button("Log", action: addNote)
                    .disabled(newNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(store.logs(forItem: itemID)) { entry in
                LogRow(entry: entry)
            }
        }
    }

    private func addNote() {
        let t = newNote.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.addNote(t, itemID: itemID)
        newNote = ""
    }
}

/// Multi-line field laid out label-above-text, so prose reads left-aligned inside a grouped form.
/// Uses a TextEditor that grows with its content (a hidden Text drives the height).
struct LongField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var monospaced = false
    var minLines = 1

    init(_ label: String, text: Binding<String>, prompt: String = "", monospaced: Bool = false, minLines: Int = 1) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.monospaced = monospaced
        self.minLines = minLines
    }

    private var font: Font { monospaced ? .body.monospaced() : .body }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                // Sizing text: same font and insets as the editor, plus trailing line so the editor never scrolls.
                Text(text + "\n" + String(repeating: "\n", count: max(minLines - 1, 0)))
                    .font(font)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                if text.isEmpty {
                    Text(prompt)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(font)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct LogRow: View {
    let entry: LogEntry
    var itemTitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(entry.author == .agent ? Color.purple : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if let itemTitle {
                    Text(itemTitle).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Text(entry.text)
                    .foregroundStyle(entry.kind == "note" ? .primary : .secondary)
                    .textSelection(.enabled)
                Text("\(entry.author == .agent ? "Assistant · " : "")\(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var symbol: String {
        if entry.author == .agent { return "sparkles" }
        switch entry.kind {
        case "created": return "plus.circle"
        case "status": return "arrow.right.circle"
        case "note": return "text.bubble"
        default: return "pencil.circle"
        }
    }
}
