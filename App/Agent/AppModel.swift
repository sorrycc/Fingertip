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
    /// The run in progress, for the status bar and the Live Activity.
    private(set) var run: RunInfo?
    /// The question the agent is waiting on.
    private(set) var pendingPrompt: UserPrompt?

    let automation = AutomationSession()
    @ObservationIgnored private var host: AgentHost?
    @ObservationIgnored private var driver: SelfRunnerDriver?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var promptTask: Task<Void, Never>?
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let notifier = PromptNotifier()
    @ObservationIgnored private var runStartedAt: Date?
    /// The app the agent was in when it brought Fingertip forward for a question.
    @ObservationIgnored private var returnBundleID: String?
    @ObservationIgnored private let builder = TranscriptBuilder()
    /// What the open agent has registered, by profile id.
    @ObservationIgnored private var registered: [String: ModelProvider] = [:]

    var isBusy: Bool { transcript.isBusy }

    init() {
        hasAPIKey = settings.selectedProvider.flatMap { APIKeyStore.key(for: $0.id) } != nil
        notifier.onAnswer = { [weak self] id, reply in self?.answer(id, reply) }
        AgentIntentRouter.answer = { [weak self] id, reply in self?.answer(id, reply) }
        AgentIntentRouter.stop = { [weak self] in await self?.stop() }
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
            watch(host.prompts)
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
        // A message while the agent waits on a question answers it.
        if let prompt = pendingPrompt, prompt.allowsText {
            return answer(prompt.id, text)
        }
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
        returnBundleID = nil
        await host?.stop()
    }

    /// Answers the agent's question, from the chat, the notification, or the Live Activity.
    func answer(_ promptID: String, _ reply: String) {
        host?.answer(promptID, reply)
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
                    await refreshRun()
                    if wasBusy, !next.isBusy { await runFinished() }
                }
            } catch {
                self?.agentError = "Lost the conversation: \(error.localizedDescription)"
            }
        }
    }

    private func watch(_ prompts: UserPrompts) {
        promptTask?.cancel()
        promptTask = Task { [weak self] in
            for await prompt in prompts.updates() {
                guard let self else { return }
                let previous = pendingPrompt
                pendingPrompt = prompt
                if let previous, previous.id != prompt?.id {
                    notifier.clear(previous.id)
                    if prompt == nil { await returnFromQuestion() }
                }
                if let prompt, prompt.id != previous?.id { await asked(prompt) }
                await refreshRun()
            }
        }
    }

    /// Reaches the user while they are elsewhere: a notification, and Fingertip itself if they chose that.
    private func asked(_ prompt: UserPrompt) async {
        guard UIApplication.shared.applicationState != .active else { return }
        await notifier.post(prompt)
        if settings.returnToAppForQuestions, automation.isReady, let bundleID = Bundle.main.bundleIdentifier, let driver,
           let host {
            returnBundleID = await host.screen.app.bundleID
            try? await driver.launchApp(bundleID: bundleID)
        }
    }

    /// Goes back to the app the agent was in before it brought Fingertip forward.
    private func returnFromQuestion() async {
        guard let bundleID = returnBundleID, let driver else { return }
        returnBundleID = nil
        guard bundleID != Bundle.main.bundleIdentifier, transcript.isBusy else { return }
        try? await driver.launchApp(bundleID: bundleID)
    }

    /// Updates the run's status bar and Live Activity from the transcript, the screen, and the step budget.
    private func refreshRun() async {
        guard let host, transcript.isBusy || pendingPrompt != nil else {
            if let run {
                self.run = nil
                runStartedAt = nil
                await liveActivity.finish(run, answer: transcript.lastAnswer, stopped: transcript.endedStopped)
            } else if !transcript.isBusy {
                await liveActivity.endAll()
            }
            return
        }
        let startedAt = runStartedAt ?? transcript.liveActivityStart ?? .now
        runStartedAt = startedAt
        let app = await host.screen.app
        let next = RunInfo(
            request: transcript.lastRequest ?? "Working",
            action: pendingPrompt.map { _ in "Waiting for you" } ?? transcript.status.summary,
            app: app.bundleID.flatMap(Transcript.appName(forBundleID:)) ?? app.name,
            steps: host.policy.stepsTaken, maxSteps: host.policy.configuration.maxStepsPerRun, startedAt: startedAt)
        if next != run { run = next }
        await liveActivity.show(next, prompt: pendingPrompt)
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
