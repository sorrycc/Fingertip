import AgentCore
import Foundation
import Security

/// An Anthropic-compatible endpoint the user can pick models from. Its key lives in the Keychain (`APIKeyStore`).
struct ProviderProfile: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    var baseURL: String
    var models: [String]
    var supportsImages = true

    static let deepSeek = ProviderProfile(
        id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", models: ["deepseek-flash"])
    static let zenMux = ProviderProfile(
        id: "zenmux", name: "ZenMux", baseURL: "https://zenmux.ai/api/anthropic",
        models: ["anthropic/claude-opus-5.5", "anthropic/claude-sonnet-5.5", "anthropic/claude-haiku-5.5"])
    static let presets = [deepSeek, zenMux]

    static func new() -> ProviderProfile {
        ProviderProfile(id: UUID().uuidString.lowercased(), name: "", baseURL: "", models: [])
    }

    var url: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host() != nil
        else { return nil }
        return url
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? url?.host() ?? "Untitled" : trimmed
    }

    /// Why this provider can't be used, if it can't.
    var problem: String? {
        if url == nil { return "Enter a full URL for \(displayName), like https://api.example.com/anthropic." }
        if models.isEmpty { return "Add at least one model to \(displayName)." }
        return nil
    }

    /// What AgentCore registers, or nil without a usable URL or key.
    func modelProvider(apiKey: String?) -> ModelProvider? {
        guard let url, let apiKey, !apiKey.isEmpty, !models.isEmpty else { return nil }
        return ModelProvider(
            id: "fingertip-\(id)", name: displayName, baseURL: url, apiKey: apiKey, modelIDs: models,
            supportsImages: supportsImages)
    }
}

/// A model of one of the providers.
struct ModelSelection: Codable, Equatable, Hashable {
    var providerID: String
    var modelID: String
}

/// User-editable configuration. API keys live in the Keychain; everything else in UserDefaults.
struct AgentSettings: Codable, Equatable {
    var providers = ProviderProfile.presets
    var selection = ModelSelection(providerID: ProviderProfile.deepSeek.id, modelID: "deepseek-flash")
    var maxStepsPerRun = 60
    var blockedApps = SafetyPolicy.Configuration.defaultBlockedApps.joined(separator: ", ")
    var returnToAppWhenDone = true

    private static let defaultsKey = "agentSettings"

    init() {}

    static func load() -> AgentSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else { return AgentSettings() }
        // Writes back a migration from the single-endpoint format.
        settings.save()
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    private enum CodingKeys: String, CodingKey {
        case providers, selection, maxStepsPerRun, blockedApps, returnToAppWhenDone
        // Before providers: one endpoint and model.
        case baseURL, modelID, supportsImages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentSettings()
        maxStepsPerRun = try container.decodeIfPresent(Int.self, forKey: .maxStepsPerRun) ?? defaults.maxStepsPerRun
        blockedApps = try container.decodeIfPresent(String.self, forKey: .blockedApps) ?? defaults.blockedApps
        returnToAppWhenDone = try container.decodeIfPresent(Bool.self, forKey: .returnToAppWhenDone) ?? defaults.returnToAppWhenDone
        if let providers = try container.decodeIfPresent([ProviderProfile].self, forKey: .providers) {
            self.providers = providers
            selection = try container.decodeIfPresent(ModelSelection.self, forKey: .selection) ?? defaults.selection
        } else {
            let baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ProviderProfile.deepSeek.baseURL
            let modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? defaults.selection.modelID
            let supportsImages = try container.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? true
            (providers, selection) = Self.migrated(baseURL: baseURL, modelID: modelID, supportsImages: supportsImages)
            APIKeyStore.migrateLegacyKey(to: selection.providerID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(selection, forKey: .selection)
        try container.encode(maxStepsPerRun, forKey: .maxStepsPerRun)
        try container.encode(blockedApps, forKey: .blockedApps)
        try container.encode(returnToAppWhenDone, forKey: .returnToAppWhenDone)
    }

    /// The presets, with the old single endpoint and model folded in.
    static func migrated(baseURL: String, modelID: String, supportsImages: Bool) -> ([ProviderProfile], ModelSelection) {
        var providers = ProviderProfile.presets
        let model = modelID.trimmingCharacters(in: .whitespaces)
        let index: Int
        if let preset = providers.firstIndex(where: { $0.baseURL == baseURL.trimmingCharacters(in: .whitespaces) }) {
            index = preset
        } else {
            providers.append(ProviderProfile(id: "custom", name: "", baseURL: baseURL, models: []))
            index = providers.count - 1
        }
        providers[index].supportsImages = supportsImages
        if !model.isEmpty, !providers[index].models.contains(model) { providers[index].models.append(model) }
        return (providers, ModelSelection(providerID: providers[index].id, modelID: model.isEmpty ? providers[index].models.first ?? "" : model))
    }

    var selectedProvider: ProviderProfile? { providers.first { $0.id == selection.providerID } }

    /// Keeps the selection pointing at an existing model, after providers or models were removed.
    mutating func fixSelection() {
        if let provider = selectedProvider, provider.models.contains(selection.modelID) { return }
        if let provider = selectedProvider ?? providers.first(where: { !$0.models.isEmpty }), let model = provider.models.first {
            selection = ModelSelection(providerID: provider.id, modelID: model)
        }
    }

    /// `blockedApps` as a list, for editing one app per row.
    var blockedAppList: [String] {
        get { blockedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { blockedApps = newValue.joined(separator: ", ") }
    }

    /// Why the model settings can't be used, if they can't.
    var modelProblem: String? {
        if providers.isEmpty { return "Add a provider." }
        if let problem = providers.lazy.compactMap(\.problem).first { return problem }
        if selectedProvider?.models.contains(selection.modelID) != true { return "Choose a model." }
        return nil
    }

    var safety: SafetyPolicy.Configuration {
        SafetyPolicy.Configuration(
            maxStepsPerRun: max(maxStepsPerRun, 1),
            blockedApps: blockedAppList)
    }
}

/// Model API keys, one per provider, in the Keychain. On first use the presets are seeded from build settings
/// (Config/Secrets.xcconfig → Info.plist), so a fresh install works without typing them:
/// DeepSeek from `AGENT_API_KEY`, ZenMux from `ZENMUX_API_KEY`.
enum APIKeyStore {
    private static let service = "com.sorrycc.fingertip.apikeys"
    /// The single key from before providers.
    private static let legacyService = "com.sorrycc.fingertip.apikey"
    private static let seeds = [ProviderProfile.deepSeek.id: "AgentDefaultAPIKey", ProviderProfile.zenMux.id: "AgentDefaultZenMuxAPIKey"]

    static func key(for provider: String) -> String? {
        if let stored = read(service: service, account: provider), !stored.isEmpty { return stored }
        guard let infoKey = seeds[provider],
              let seeded = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
              !seeded.isEmpty, !seeded.hasPrefix("$(")
        else { return nil }
        write(seeded, service: service, account: provider)
        return seeded
    }

    static func setKey(_ value: String?, for provider: String) {
        write(value, service: service, account: provider)
    }

    /// Moves the key from before providers to `provider`.
    static func migrateLegacyKey(to provider: String) {
        guard let legacy = read(service: legacyService, account: nil), !legacy.isEmpty else { return }
        if read(service: service, account: provider) == nil { write(legacy, service: service, account: provider) }
        write(nil, service: legacyService, account: nil)
    }

    private static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static func read(service: String, account: String?) -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?, service: String, account: String?) {
        let query = query(service: service, account: account)
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
