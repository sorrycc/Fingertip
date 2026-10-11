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
    /// Set when model, URL, or key changed after the agent opened; those apply on the next launch.
    private(set) var needsRelaunch = false
    private(set) var hasAPIKey = APIKeyStore.key != nil

    let automation = AutomationSession()
    @ObservationIgnored private var host: AgentHost?
    @ObservationIgnored private var driver: SelfRunnerDriver?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let builder = TranscriptBuilder()
    @ObservationIgnored private var openedWith: (config: AgentConfig, apiKey: String)?

    var isBusy: Bool { transcript.isBusy }

    /// Opens the agent; reopening resumes any run iOS interrupted.
    func openAgent() async {
        guard host == nil, !isOpening else { return }
        guard let config = settings.agentConfig else { return agentError = "The base URL in Settings isn't valid." }
        guard let apiKey = APIKeyStore.key else { return agentError = "Add an API key in Settings to get started." }
        isOpening = true
        defer { isOpening = false }
        do {
            let driver = SelfRunnerDriver()
            let storage = Storage.sqlite(at: URL.applicationSupportDirectory.appending(path: "agent.sqlite"))
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            let host = try await AgentHost.open(
                config: config, apiKey: apiKey, storage: storage, driver: driver, safety: settings.safety,
                credentials: KeychainCredentialStore.keychain(service: "com.sorrycc.fingertip.models"),
                onReport: { message in print("[pi-durable] \(message)") })
            self.host = host
            self.driver = driver
            openedWith = (config, apiKey)
            agentError = nil
            watch(host.conversation)
        } catch {
            agentError = "Couldn't open the agent: \(error.localizedDescription)"
        }
    }

    /// Saves settings. Safety changes apply now; model changes apply now if the agent hasn't opened yet.
    func save(_ settings: AgentSettings, apiKey: String) async {
        self.settings = settings
        settings.save()
        APIKeyStore.key = apiKey
        hasAPIKey = !apiKey.isEmpty
        host?.policy.configuration = settings.safety
        if let openedWith {
            needsRelaunch = settings.agentConfig != openedWith.config || apiKey != openedWith.apiKey
        } else {
            agentError = nil
            await openAgent()
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
