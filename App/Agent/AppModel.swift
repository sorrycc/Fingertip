import AgentCore
import Observation
import PiDurableKit
import SwiftUI
import UserNotifications

/// App state: the automation session, the durable agent, and the transcript the chat shows.
@Observable
@MainActor
final class AppModel {
    private(set) var settings = AgentSettings.load()
    private(set) var transcript = Transcript()
    private(set) var agentError: String?
    private(set) var isOpening = false
    /// Whether the selected model's provider has a key.
    private(set) var hasAPIKey = false

    let automation = AutomationSession()
    @ObservationIgnored private var host: AgentHost?
    @ObservationIgnored private var driver: SelfRunnerDriver?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let builder = TranscriptBuilder()
    /// What the open agent has registered, by profile id.
    @ObservationIgnored private var registered: [String: ModelProvider] = [:]

    var isBusy: Bool { transcript.isBusy }

    init() {
        hasAPIKey = settings.selectedProvider.flatMap { APIKeyStore.key(for: $0.id) } != nil
    }

    /// The providers that can be registered: a valid URL, models, and a key.
    private var usableProviders: [String: ModelProvider] {
        Dictionary(uniqueKeysWithValues: settings.providers.compactMap { profile in
            profile.modelProvider(apiKey: APIKeyStore.key(for: profile.id)).map { (profile.id, $0) }
        })
    }

    /// Opens the agent; reopening resumes any run iOS interrupted.
    func openAgent() async {
        guard host == nil, !isOpening else { return }
        if let problem = settings.modelProblem { return agentError = problem }
        let providers = usableProviders
        guard let selected = providers[settings.selection.providerID] else {
            return agentError = "Add an API key for \(settings.selectedProvider?.displayName ?? "the provider") in Settings to get started."
        }
        isOpening = true
        defer { isOpening = false }
        do {
            let driver = SelfRunnerDriver()
            let storage = Storage.sqlite(at: URL.applicationSupportDirectory.appending(path: "agent.sqlite"))
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            let host = try await AgentHost.open(
                providers: Array(providers.values), model: settings.selection.modelID, of: selected,
                storage: storage, driver: driver, safety: settings.safety,
                credentials: KeychainCredentialStore.keychain(service: "com.sorrycc.fingertip.models"),
                onReport: { message in print("[pi-durable] \(message)") })
            self.host = host
            self.driver = driver
            registered = providers
            agentError = nil
            watch(host.conversation)
        } catch {
            agentError = "Couldn't open the agent: \(error.localizedDescription)"
        }
    }

    /// Saves settings and keys (by profile id). Everything applies now; a model change from the next model request.
    func save(_ settings: AgentSettings, apiKeys: [String: String]) async {
        for (provider, key) in apiKeys { APIKeyStore.setKey(key, for: provider) }
        for removed in self.settings.providers where !settings.providers.contains(where: { $0.id == removed.id }) {
            APIKeyStore.setKey(nil, for: removed.id)
        }
        await apply(settings)
    }

    /// Switches the model, from the chat's model menu.
    func select(_ selection: ModelSelection) async {
        var settings = settings
        settings.selection = selection
        await apply(settings)
    }

    private func apply(_ settings: AgentSettings) async {
        self.settings = settings
        settings.save()
        hasAPIKey = settings.selectedProvider.flatMap { APIKeyStore.key(for: $0.id) } != nil
        guard let host else {
            agentError = nil
            return await openAgent()
        }
        host.policy.configuration = settings.safety
        do {
            let providers = usableProviders
            for (id, provider) in providers where registered[id] != provider { try await host.register(provider) }
            registered = providers
            guard let selected = providers[settings.selection.providerID] else {
                return agentError = "Add an API key for \(settings.selectedProvider?.displayName ?? "the provider") in Settings."
            }
            try await host.select(settings.selection.modelID, of: selected)
            agentError = nil
        } catch {
            agentError = "Couldn't switch the model: \(error.localizedDescription)"
        }
    }

    func send(_ text: String) async {
        guard automation.isReady else { return agentError = "Start UI automation first, then try again." }
        await openAgent()
        guard let host else { return }
        agentError = nil
        requestNotificationPermission()
        do {
            try await host.send(text)
        } catch {
            agentError = error.localizedDescription
        }
    }

    func stop() async {
        await host?.stop()
    }

    func newTask() async {
        do { try await host?.newTask() } catch { agentError = error.localizedDescription }
    }

    func dismissError() { agentError = nil }

    // MARK: Watching

    private func watch(_ conversation: Conversation) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            do {
                for try await view in conversation.views() {
                    guard let self else { return }
                    let wasBusy = transcript.isBusy
                    let next = builder.build(view)
                    if next != transcript { transcript = next }
                    if wasBusy, !next.isBusy { await runFinished() }
                }
            } catch {
                self?.agentError = "Lost the conversation: \(error.localizedDescription)"
            }
        }
    }

    /// Comes back to the chat and notifies, like the demo returning with the answer.
    private func runFinished() async {
        let answer = transcript.lastAnswer ?? "Done."
        if settings.returnToAppWhenDone, UIApplication.shared.applicationState != .active, automation.isReady,
           let bundleID = Bundle.main.bundleIdentifier, let driver {
            try? await driver.launchApp(bundleID: bundleID)
        }
        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = "Agent finished"
            content.body = String(answer.prefix(240))
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
