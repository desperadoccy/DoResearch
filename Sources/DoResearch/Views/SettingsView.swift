import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettings()
                .tabItem { Label("Providers", systemImage: "cpu") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 720, height: 520)
    }
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
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
    }
}

// MARK: - Providers

private struct ProvidersSettings: View {
    @Environment(ProviderStore.self) private var providers
    @State private var selection: String?
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(providers.providers) { p in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                    Text(p.displayModel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } icon: {
                                Image(systemName: p.symbol)
                            }
                            Spacer()
                            if p.id == providers.activeID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    .help("Used by the assistant")
                            }
                        }
                        .tag(p.id)
                    }
                    .onMove { providers.move(from: $0, to: $1) }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        ForEach(ProviderPreset.all) { preset in
                            Button(preset.name) { selection = providers.add(from: preset).id }
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a provider")
                    Divider().frame(height: 16)
                    Button {
                        confirmingRemove = true
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil || providers.providers.count < 2)
                    .help("Remove the selected provider")
                    Spacer()
                }
                .padding(4)
            }
            .frame(width: 220)

            Divider()

            if let id = selection, providers.provider(id) != nil {
                ProviderDetail(id: id).id(id)
            } else {
                ContentUnavailableView("No Provider Selected", systemImage: "cpu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = providers.activeID } }
        .confirmationDialog("Remove “\(providers.provider(selection)?.name ?? "")”?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) {
                if let id = selection {
                    providers.remove(id)
                    selection = providers.activeID
                }
            }
        } message: {
            Text("Its saved API key is deleted from the Keychain.")
        }
    }
}

private struct ProviderDetail: View {
    let id: String
    @Environment(ProviderStore.self) private var providers
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var fetchedModels: [String] = []
    @State private var fetchError: String?
    @State private var fetching = false
    @State private var testing = false
    @State private var testResult: AgentSession.TestResult?
    @State private var newModel = ""

    private var config: ProviderConfig { providers.provider(id) ?? ProviderConfig(id: id, name: "", kind: .openAICompatible, baseURL: "", model: "") }

    private func bind<T>(_ kp: WritableKeyPath<ProviderConfig, T>) -> Binding<T> {
        Binding(get: { config[keyPath: kp] }, set: { value in
            var c = config
            c[keyPath: kp] = value
            providers.update(c)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            actionBar
        }
        .onAppear { apiKey = Keychain.read(account: Keychain.account(forProvider: id)) ?? "" }
        .onChange(of: config.baseURL) { fetchedModels = []; fetchError = nil; testResult = nil }
        .onChange(of: config.kind) { fetchedModels = []; fetchError = nil; testResult = nil }
        .onChange(of: config.model) { testResult = nil }
    }

    /// Kept outside the scrolling form so testing and activating are always one click away.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = testResult {
                Label(r.message, systemImage: r.level == .ok ? "checkmark.circle" : r.level == .warning ? "exclamationmark.triangle" : "xmark.octagon")
                    .foregroundStyle(r.level == .ok ? Color.green : r.level == .warning ? Color.orange : Color.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(testing ? "Testing…" : "Test Connection") { runTest() }
                    .disabled(testing || config.model.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                if config.id == providers.activeID {
                    Label("Used by the assistant", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Use for Assistant") { providers.activeID = id }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: bind(\.name))
                Picker("API", selection: bind(\.kind)) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Base URL") {
                    TextField("Base URL", text: bind(\.baseURL), prompt: Text(config.kind == .anthropic ? "https://api.anthropic.com" : "https://host/v1"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                if config.isInsecure {
                    Label("Plain HTTP sends prompts and the API key unencrypted. Use https:// for remote servers.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    SecureField("API Key", text: $apiKey, prompt: Text(config.requiresKey ? "Required" : "Optional for local servers"))
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(apiKey == (Keychain.read(account: Keychain.account(forProvider: id)) ?? ""))
                }
                keyFooter
            }

            Section("Model") {
                modelPicker
                if config.kind == .anthropic {
                    Picker("Effort", selection: bind(\.effort)) {
                        Text("Model Default").tag(String?.none)
                        ForEach(ProviderConfig.anthropicEfforts, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                } else {
                    Picker("Reasoning Effort", selection: bind(\.reasoningEffort)) {
                        Text("Don't Send").tag(String?.none)
                        ForEach(ProviderConfig.reasoningEfforts, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                    Text("Only for reasoning models that accept `reasoning_effort` (e.g. OpenAI o-series). Other servers may reject it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(config.models, id: \.self) { m in
                    HStack {
                        Text(m).font(.body.monospaced())
                        Spacer()
                        Button {
                            var c = config
                            c.models.removeAll { $0 == m }
                            providers.update(c)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add model", text: $newModel, prompt: Text("model id"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .onSubmit(addModel)
                    Button("Add", action: addModel).disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Quick Switch Models")
            } footer: {
                Text("Listed in the assistant's model menu so you can switch without opening Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var keyFooter: some View {
        HStack {
            if keySaved {
                Text("Saved to Keychain.").font(.caption).foregroundStyle(.secondary)
            } else if Keychain.read(account: Keychain.account(forProvider: id)) == nil, config.apiKey != nil {
                Text("Using the key from the environment.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = ProviderPreset.matching(config)?.keyURL.flatMap(URL.init(string:)) {
                Link("Get an API key", destination: url).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let options = Array(NSOrderedSet(array: config.switcherModels + fetchedModels)) as? [String] ?? []
        LabeledContent("Model") {
          HStack {
            TextField("Model", text: bind(\.model), prompt: Text("model id"))
                .labelsHidden()
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
            Menu {
                if options.isEmpty {
                    Text(fetching ? "Loading…" : "No models loaded")
                }
                ForEach(options, id: \.self) { m in
                    Button(m) { bind(\.model).wrappedValue = m }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a model")
            Button {
                fetchModels()
            } label: {
                if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(fetching)
            .help("Load the model list from the server")
          }
        }
        if let fetchError {
            Text(fetchError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        } else if !fetchedModels.isEmpty {
            Text("\(fetchedModels.count) models available from the server.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        providers.setKey(apiKey, for: id)
        keySaved = true
        testResult = nil
    }

    private func addModel() {
        let m = newModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        var c = config
        if !c.models.contains(m) { c.models.append(m) }
        if c.model.isEmpty { c.model = m }
        providers.update(c)
        newModel = ""
    }

    private func fetchModels() {
        fetching = true
        fetchError = nil
        let snapshot = config
        Task {
            do {
                let models = try await makeClient(for: snapshot).listModels()
                fetchedModels = models
                if models.isEmpty { fetchError = "The server returned no models." }
                if config.model.isEmpty, let first = models.first { bind(\.model).wrappedValue = first }
            } catch {
                fetchError = error.localizedDescription
            }
            fetching = false
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        let snapshot = config
        Task {
            testResult = await AgentSession.test(snapshot)
            testing = false
        }
    }
}
