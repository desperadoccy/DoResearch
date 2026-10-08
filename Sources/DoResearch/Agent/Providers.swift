import Foundation
import Observation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible = "openai"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .anthropic: "Anthropic Messages API"
        case .openAICompatible: "OpenAI-compatible (Chat Completions)"
        }
    }
}

/// One configured model endpoint. The API key lives in the Keychain, keyed by `id`.
struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ProviderKind
    var baseURL: String
    /// The model the assistant uses with this provider.
    var model: String
    /// Models offered in the quick switcher (picked from the server's list or typed in).
    var models: [String] = []
    /// Anthropic `output_config.effort`; nil leaves the model's default.
    var effort: String?
    /// OpenAI `reasoning_effort`; nil omits it (many compatible servers reject unknown fields).
    var reasoningEffort: String?

    init(id: String, name: String, kind: ProviderKind, baseURL: String, model: String, models: [String] = [],
         effort: String? = nil, reasoningEffort: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.models = models
        self.effort = effort
        self.reasoningEffort = reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .openAICompatible
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        models = try c.decodeIfPresent([String].self, forKey: .models) ?? []
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }

    /// Models for the switcher: the saved list, always including the current model.
    var switcherModels: [String] {
        var list = models
        if !model.isEmpty, !list.contains(model) { list.insert(model, at: 0) }
        return list
    }

    static let anthropicEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let reasoningEfforts = ["minimal", "low", "medium", "high"]

    var apiKey: String? {
        if let key = Keychain.read(account: Keychain.account(forProvider: id)) { return key }
        // Handy when launching from a terminal.
        let env = ProcessInfo.processInfo.environment
        switch kind {
        case .anthropic: return env["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        case .openAICompatible:
            return host == "api.openai.com" ? env["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } : nil
        }
    }

    var host: String { URL(string: baseURL)?.host?.lowercased() ?? "" }

    var isLocal: Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
    }

    /// Local servers (Ollama, LM Studio, local gateways) usually run without a key.
    var requiresKey: Bool { !isLocal }

    /// Plain HTTP to a non-local host sends prompts (and the key) unencrypted.
    var isInsecure: Bool { baseURL.lowercased().hasPrefix("http://") && !isLocal }

    var displayModel: String { model.isEmpty ? "No model" : model }
}

/// Starting points for new providers.
struct ProviderPreset: Identifiable {
    let id: String
    let name: String
    let kind: ProviderKind
    let baseURL: String
    let model: String
    let suggestedModels: [String]
    let keyURL: String?

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com",
                       model: "claude-opus-5-5", suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                       keyURL: "https://platform.claude.com/settings/keys"),
        ProviderPreset(id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
                       model: "", suggestedModels: [], keyURL: "https://platform.openai.com/api-keys"),
        ProviderPreset(id: "openrouter", name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
                       model: "", suggestedModels: [], keyURL: "https://openrouter.ai/keys"),
        ProviderPreset(id: "deepseek", name: "DeepSeek", kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1",
                       model: "", suggestedModels: [], keyURL: "https://platform.deepseek.com/api_keys"),
        ProviderPreset(id: "ollama", name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1",
                       model: "", suggestedModels: [], keyURL: nil),
        ProviderPreset(id: "lmstudio", name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1",
                       model: "", suggestedModels: [], keyURL: nil),
        ProviderPreset(id: "custom", name: "Custom (OpenAI-compatible)", kind: .openAICompatible, baseURL: "https://",
                       model: "", suggestedModels: [], keyURL: nil),
    ]

    static func matching(_ config: ProviderConfig) -> ProviderPreset? {
        all.first { $0.kind == config.kind && $0.baseURL == config.baseURL && $0.id != "custom" }
    }
}

/// The saved providers and which one the assistant uses. Persisted in UserDefaults (keys excepted).
@Observable
@MainActor
final class ProviderStore {
    private(set) var providers: [ProviderConfig] = []
    var activeID: String {
        didSet { defaults.set(activeID, forKey: Self.activeKey) }
    }

    private let defaults: UserDefaults
    private static let listKey = "providers"
    private static let activeKey = "activeProviderID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeID = defaults.string(forKey: Self.activeKey) ?? ""
        if let data = defaults.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data), !saved.isEmpty {
            providers = saved
        } else {
            providers = [Self.migratedDefault(defaults)]
            persist()
        }
        if active == nil { activeID = providers[0].id }
    }

    var active: ProviderConfig? { providers.first { $0.id == activeID } }

    func provider(_ id: String?) -> ProviderConfig? { providers.first { $0.id == id } }

    @discardableResult
    func add(from preset: ProviderPreset) -> ProviderConfig {
        var name = preset.id == "custom" ? "Custom" : preset.name
        let taken = Set(providers.map(\.name))
        if taken.contains(name) {
            var n = 2
            while taken.contains("\(name) \(n)") { n += 1 }
            name = "\(name) \(n)"
        }
        let config = ProviderConfig(id: ShortID.make(), name: name, kind: preset.kind, baseURL: preset.baseURL,
                                    model: preset.model, models: preset.suggestedModels,
                                    effort: preset.kind == .anthropic ? "medium" : nil)
        providers.append(config)
        persist()
        return config
    }

    func update(_ config: ProviderConfig) {
        guard let i = providers.firstIndex(where: { $0.id == config.id }), providers[i] != config else { return }
        providers[i] = config
        persist()
    }

    /// Makes `model` on provider `id` the assistant's model.
    func select(_ id: String, model: String) {
        guard var p = provider(id) else { return }
        if p.model != model {
            p.model = model
            update(p)
        }
        activeID = id
    }

    func remove(_ id: String) {
        guard providers.count > 1 else { return }
        providers.removeAll { $0.id == id }
        Keychain.save("", account: Keychain.account(forProvider: id))
        if activeID == id { activeID = providers[0].id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func setKey(_ key: String, for id: String) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.account(forProvider: id))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) { defaults.set(data, forKey: Self.listKey) }
    }

    /// First launch after providers were added: carry over the old single-provider Anthropic settings.
    private static func migratedDefault(_ defaults: UserDefaults) -> ProviderConfig {
        let config = ProviderConfig(
            id: "anthropic", name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com",
            model: defaults.string(forKey: "agentModel") ?? "claude-opus-5-5",
            models: ProviderPreset.all[0].suggestedModels,
            effort: defaults.string(forKey: "agentEffort") ?? "medium"
        )
        if let legacy = Keychain.read(account: Keychain.legacyAccount) {
            if Keychain.save(legacy, account: Keychain.account(forProvider: config.id)) {
                Keychain.save("", account: Keychain.legacyAccount)
            }
        }
        return config
    }
}
