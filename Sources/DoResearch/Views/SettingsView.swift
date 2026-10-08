import SwiftUI

struct SettingsView: View {
    @AppStorage("agentModel") private var model = ClaudeClient.defaultModel
    @AppStorage("agentEffort") private var effort = ClaudeClient.defaultEffort
    @State private var apiKey = ""
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey, prompt: Text("sk-ant-…"))
                HStack {
                    if let savedMessage {
                        Text(savedMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        Keychain.saveAPIKey("")
                        apiKey = ""
                        savedMessage = "Removed."
                    }
                    Button("Save") {
                        let ok = Keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        savedMessage = ok ? "Saved to Keychain." : "Could not save to Keychain."
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Anthropic API")
            } footer: {
                Text("Stored in your login Keychain. If none is saved, ANTHROPIC_API_KEY from the environment is used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Assistant") {
                Picker("Model", selection: $model) {
                    ForEach(ClaudeClient.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: $effort) {
                    ForEach(ClaudeClient.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Text("Higher effort thinks longer and costs more. Medium suits day-to-day organizing; use High for detailed reviews and planning.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Database") {
                    Text(Database.defaultURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Database.defaultURL])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { apiKey = Keychain.readAPIKey() ?? "" }
    }
}
