import SwiftUI

extension ProviderConfig {
    var symbol: String {
        if kind == .anthropic { return "sparkle" }
        if isLocal { return "desktopcomputer" }
        return "cloud"
    }
}

/// Header menu in the assistant panel: pick a provider, or a specific model of one, in a single click.
struct ProviderSwitcher: View {
    @Environment(ProviderStore.self) private var providers
    @Environment(AgentSession.self) private var agent

    var body: some View {
        Menu {
            ForEach(providers.providers) { p in
                let models = p.switcherModels
                let isActive = p.id == providers.activeID
                if models.count > 1 {
                    Menu {
                        ForEach(models, id: \.self) { m in
                            Toggle(m, isOn: selected(p.id, m))
                        }
                    } label: {
                        if isActive { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                } else {
                    Toggle("\(p.name) · \(p.displayModel)", isOn: selected(p.id, p.model))
                }
            }
            Divider()
            SettingsLink { Text("Manage Providers…") }
        } label: {
            if let p = providers.active {
                Label("\(p.name) · \(p.displayModel)", systemImage: p.symbol)
            } else {
                Text("No Provider")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .disabled(agent.isRunning)
        .help(agent.isRunning ? "You can switch once the current reply finishes" : "Choose the model provider")
    }

    private func selected(_ id: String, _ model: String) -> Binding<Bool> {
        Binding(
            get: { providers.activeID == id && providers.active?.model == model },
            set: { if $0 { providers.select(id, model: model) } }
        )
    }
}

/// Assistant menu in the menu bar, with ⌃⌘1…9 to jump between providers.
struct AssistantCommands: Commands {
    let providers: ProviderStore
    let agent: AgentSession
    let app: AppState

    var body: some Commands {
        CommandMenu("Assistant") {
            Button(app.showAgent ? "Hide Assistant" : "Show Assistant") { app.showAgent.toggle() }
                .keyboardShortcut("j")
            Button("New Conversation") { agent.reset() }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Section("Provider") {
                ForEach(Array(providers.providers.enumerated()), id: \.element.id) { index, p in
                    let toggle = Toggle("\(p.name) · \(p.displayModel)", isOn: Binding(
                        get: { providers.activeID == p.id },
                        set: { if $0 { providers.activeID = p.id } }
                    ))
                    .disabled(agent.isRunning)
                    if index < 9 {
                        toggle.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .control])
                    } else {
                        toggle
                    }
                }
            }
        }
    }
}
