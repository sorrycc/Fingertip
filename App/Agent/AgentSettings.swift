import AgentCore
import Foundation
import Security

/// User-editable configuration. The API key lives in the Keychain; everything else in UserDefaults.
struct AgentSettings: Codable, Equatable {
    var baseURL = "https://api.deepseek.com/anthropic"
    var modelID = "deepseek-flash"
    var supportsImages = true
    var maxStepsPerRun = 60
    var blockedApps = SafetyPolicy.Configuration.defaultBlockedApps.joined(separator: ", ")
    var returnToAppWhenDone = true

    private static let defaultsKey = "agentSettings"

    static func load() -> AgentSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AgentSettings.self, from: data)
        else { return AgentSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    var agentConfig: AgentConfig? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return nil }
        return AgentConfig(baseURL: url, modelID: modelID.trimmingCharacters(in: .whitespaces), supportsImages: supportsImages)
    }

    var safety: SafetyPolicy.Configuration {
        SafetyPolicy.Configuration(
            maxStepsPerRun: max(maxStepsPerRun, 1),
            blockedApps: blockedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

/// The model API key, in the Keychain. On first launch it is seeded from the build setting `AGENT_API_KEY`
/// (Config/Secrets.xcconfig → Info.plist `AgentDefaultAPIKey`), so a fresh install works without typing it.
enum APIKeyStore {
    private static let service = "com.sorrycc.iphoneagent.apikey"

    static var key: String? {
        get {
            if let stored = read(), !stored.isEmpty { return stored }
            guard let seeded = Bundle.main.object(forInfoDictionaryKey: "AgentDefaultAPIKey") as? String,
                  !seeded.isEmpty, !seeded.hasPrefix("$(")
            else { return nil }
            write(seeded)
            return seeded
        }
        set { write(newValue) }
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
