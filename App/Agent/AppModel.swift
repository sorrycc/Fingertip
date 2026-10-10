import AgentCore
import PiDurableKit
import SwiftUI
import UserNotifications

/// App state: the automation session, the durable agent, and the conversation the chat shows.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AgentSettings.load()
    @Published private(set) var view: ConversationView?
    @Published private(set) var agentError: String?
    @Published private(set) var isOpening = false

    let automation = AutomationSession()
    private var host: AgentHost?
    private var driver: SelfRunnerDriver?
    private var watchTask: Task<Void, Never>?
    private var wasBusy = false

    var isBusy: Bool { view?.isBusy ?? false }
    var hasAPIKey: Bool { APIKeyStore.key != nil }

    /// Opens the agent; reopening resumes any run iOS interrupted.
    func openAgent() async {
        guard host == nil, !isOpening else { return }
        guard let config = settings.agentConfig else { return agentError = "Invalid base URL in Settings" }
        guard let apiKey = APIKeyStore.key else { return agentError = "Add an API key in Settings" }
        isOpening = true
        defer { isOpening = false }
        do {
            let driver = SelfRunnerDriver()
            let storage = Storage.sqlite(at: URL.applicationSupportDirectory.appending(path: "agent.sqlite"))
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            let host = try await AgentHost.open(
                config: config, apiKey: apiKey, storage: storage, driver: driver, safety: settings.safety,
                credentials: KeychainCredentialStore.keychain(service: "com.sorrycc.iphoneagent.models"),
                onReport: { message in print("[pi-durable] \(message)") })
            self.host = host
            self.driver = driver
            agentError = nil
            watch(host.conversation)
        } catch {
            agentError = "Could not open agent: \(error.localizedDescription)"
        }
    }

    func applySettings() {
        settings.save()
        host?.policy.configuration = settings.safety
    }

    func send(_ text: String) async {
        guard automation.isReady else { return agentError = "Start UI automation in Setup first." }
        await openAgent()
        guard let host else { return }
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

    // MARK: Watching

    private func watch(_ conversation: Conversation) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            do {
                for try await view in conversation.views() {
                    guard let self else { return }
                    self.view = view
                    if self.wasBusy, !view.isBusy { await self.runFinished(view) }
                    self.wasBusy = view.isBusy
                }
            } catch {
                self?.agentError = "Conversation stream ended: \(error.localizedDescription)"
            }
        }
    }

    /// Comes back to the chat and notifies, like the demo returning with the answer.
    private func runFinished(_ view: ConversationView) async {
        let answer = view.entries.last(where: { $0.kind == .assistant })?.assistantMessage?.text ?? "Done."
        if settings.returnToAppWhenDone, UIApplication.shared.applicationState != .active, automation.isReady,
           let bundleID = Bundle.main.bundleIdentifier, let driver {
            try? await driver.launchApp(bundleID: bundleID)
        }
        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = "Agent finished"
            content.body = String(answer.prefix(240))
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
