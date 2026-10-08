import SwiftUI

struct AgentChatView: View {
    @Environment(AgentSession.self) private var agent
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "What should I focus on today?",
        "Review my research progress this week",
        "Plan an ablation study for the item I'm viewing",
        "Triage my inbox",
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if agent.entries.isEmpty {
                            emptyState
                        }
                        ForEach(agent.entries) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                        if agent.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working…").foregroundStyle(.secondary)
                            }
                            .id("working")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: agent.entries.count) {
                    withAnimation { proxy.scrollTo(agent.entries.last?.id, anchor: .bottom) }
                }
                .onChange(of: agent.isRunning) {
                    if agent.isRunning { withAnimation { proxy.scrollTo("working", anchor: .bottom) } }
                }
            }
            Divider()
            composer
        }
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack {
            Label("Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Text(ClaudeClient.models.first { $0.id == agent.model }?.name ?? agent.model)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                agent.reset()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New conversation")
            .disabled(agent.entries.isEmpty && !agent.isRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask me to capture, organize, update, or review your work. I can create items and projects, log experiment results, update coding progress, and summarize where things stand.")
                .foregroundStyle(.secondary)
            if !agent.hasAPIKey {
                HStack {
                    Image(systemName: "key").foregroundStyle(.orange)
                    Text("Add your Anthropic API key to get started.")
                    SettingsLink { Text("Open Settings…") }
                }
                .font(.callout)
            }
            ForEach(suggestions, id: \.self) { s in
                Button {
                    agent.send(s)
                } label: {
                    Text(s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, prompt: Text("Ask or tell the assistant…"), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            if agent.isRunning {
                Button {
                    agent.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .help("Stop")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
        }
        .padding(10)
    }

    private func submit() {
        guard !agent.isRunning else { return }
        agent.send(draft)
        draft = ""
    }

    static func context(store: Store, app: AppState) -> String? {
        var lines: [String] = []
        switch app.selection {
        case .project(let id): if let p = store.project(id) { lines.append("Viewing project “\(p.name)” (id \(p.id)).") }
        case .kind(let k): lines.append("Viewing the \(k.pluralLabel) list.")
        case .review: lines.append("Viewing the Review dashboard.")
        case .some(let s): lines.append("Viewing the \(String(describing: s).capitalized) list.")
        case .none: break
        }
        let selected = ItemActions(store: store, app: app).ordered(app.selectedItemIDs)
        if selected.count == 1, let item = selected.first {
            lines.append("Selected item: “\(item.title)” (id \(item.id), \(item.kind.rawValue), \(item.statusLabel)).")
        } else if !selected.isEmpty {
            lines.append("Selected \(selected.count) items:")
            lines += selected.prefix(30).map { "- “\($0.title)” (id \($0.id), \($0.kind.rawValue), \($0.statusLabel))" }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private struct EntryView: View {
    let entry: AgentSession.Entry

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        case .assistant:
            Text(markdown(entry.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: entry.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(entry.isError ? Color.orange : Color.secondary)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
                .font(.callout)
        case .notice:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
