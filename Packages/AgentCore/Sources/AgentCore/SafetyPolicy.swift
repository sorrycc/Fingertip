import Foundation
import os
import PiDurableKit

/// Guards the computer-use actions: a per-run step budget, a stop switch, apps the agent may not touch, and actions
/// that need the user's approval first.
public final class SafetyPolicy: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Device actions allowed per user request.
        public var maxStepsPerRun: Int
        /// Bundle ids (or app names) where actions are blocked.
        public var blockedApps: [String]
        /// Action tools (`open_url`, `type_text`, …) that wait for the user's approval each time.
        public var confirmTools: [String]
        /// Bundle ids (or app names) where every action waits for the user's approval.
        public var confirmApps: [String]

        public init(
            maxStepsPerRun: Int = 60, blockedApps: [String] = Configuration.defaultBlockedApps,
            confirmTools: [String] = [], confirmApps: [String] = []
        ) {
            self.maxStepsPerRun = maxStepsPerRun
            self.blockedApps = blockedApps
            self.confirmTools = confirmTools
            self.confirmApps = confirmApps
        }

        private enum CodingKeys: String, CodingKey { case maxStepsPerRun, blockedApps, confirmTools, confirmApps }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                maxStepsPerRun: try container.decodeIfPresent(Int.self, forKey: .maxStepsPerRun) ?? 60,
                blockedApps: try container.decodeIfPresent([String].self, forKey: .blockedApps) ?? Self.defaultBlockedApps,
                confirmTools: try container.decodeIfPresent([String].self, forKey: .confirmTools) ?? [],
                confirmApps: try container.decodeIfPresent([String].self, forKey: .confirmApps) ?? [])
        }

        public static let defaultBlockedApps = [
            "com.apple.Passbook",  // Wallet
            "com.apple.Health",
            "com.apple.Passwords",
        ]
    }

    struct State {
        var configuration: Configuration
        var steps = 0
        var stopped = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let screen: ScreenState
    /// Where approval questions (and the model's `ask_user`) wait for the user.
    public let prompts: UserPrompts

    public init(configuration: Configuration = .init(), screen: ScreenState, prompts: UserPrompts = UserPrompts()) {
        state = OSAllocatedUnfairLock(initialState: State(configuration: configuration))
        self.screen = screen
        self.prompts = prompts
    }

    public var configuration: Configuration {
        get { state.withLock { $0.configuration } }
        set { state.withLock { $0.configuration = newValue } }
    }

    public var stepsTaken: Int { state.withLock { $0.steps } }

    /// Call before submitting a new user request.
    public func beginRun() {
        state.withLock {
            $0.steps = 0
            $0.stopped = false
        }
    }

    /// Blocks every further action until the next `beginRun()`, and cancels a question waiting for the user.
    public func requestStop() {
        state.withLock { $0.stopped = true }
        prompts.cancelAll()
    }

    public var isStopped: Bool { state.withLock { $0.stopped } }

    enum Verdict: Equatable {
        case allow
        case block(String)
    }

    /// Stop, blocked apps, and the step budget, in one go.
    func check(tool: String, app: AppInfo) -> Verdict {
        if case .block(let message) = gate(tool: tool, app: app) { return .block(message) }
        return count(tool: tool)
    }

    /// The stop switch and blocked apps; doesn't use up a step.
    func gate(tool: String, app: AppInfo) -> Verdict {
        guard ComputerUse.actionTools.contains(tool) else { return .allow }
        return state.withLock { state in
            if state.stopped { return .block(Self.stoppedMessage) }
            let blocked = state.configuration.blockedApps.map { $0.lowercased() }
            let current = [app.bundleID, app.name].compactMap { $0?.lowercased() }
            if !Self.leavesApp(tool), current.contains(where: blocked.contains) {
                return .block("Actions in \(app.display) are blocked by the user's safety settings. Leave this app (press_home) or stop.")
            }
            return .allow
        }
    }

    /// Uses up a step of the budget.
    func count(tool: String) -> Verdict {
        guard ComputerUse.actionTools.contains(tool) else { return .allow }
        return state.withLock { state in
            if state.stopped { return .block(Self.stoppedMessage) }
            state.steps += 1
            if state.steps > state.configuration.maxStepsPerRun {
                return .block("Step budget of \(state.configuration.maxStepsPerRun) actions for this request is used up. Stop and report progress to the user.")
            }
            return .allow
        }
    }

    /// Whether this action needs the user's approval: a listed tool, or any action in a listed app.
    func needsApproval(tool: String, app: AppInfo) -> Bool {
        guard ComputerUse.actionTools.contains(tool) else { return false }
        let configuration = configuration
        if configuration.confirmTools.contains(where: { $0.caseInsensitiveCompare(tool) == .orderedSame }) { return true }
        let apps = configuration.confirmApps.map { $0.lowercased() }
        let current = [app.bundleID, app.name].compactMap { $0?.lowercased() }
        return !Self.leavesApp(tool) && current.contains(where: apps.contains)
    }

    /// Asks the user before a listed action; waits until they answer or stop.
    func approve(tool: String, action: String, app: AppInfo) async -> Verdict {
        guard needsApproval(tool: tool, app: app) else { return .allow }
        let place = app.name ?? app.bundleID.map { AppLookup.name(forBundleID: $0) ?? $0 }
        let question = "Allow the agent to \(action)" + (place.map { " in \($0)" } ?? "") + "?"
        let prompt = UserPrompt(
            question: question, options: [UserPrompt.approve, UserPrompt.deny], allowsText: false, source: .policy)
        switch await prompts.ask(prompt) {
        case .answered(UserPrompt.approve):
            return .allow
        case .answered:
            return .block("The user did not allow this action (\(action)). Do not try it another way; ask the user with ask_user or stop and report.")
        case .cancelled:
            return .block(Self.stoppedMessage)
        }
    }

    private static let stoppedMessage = "The user pressed Stop. Do not take any more actions; summarize what you did and what is left."

    /// Tools that take the agent out of the current app, which a blocked app must still allow.
    private static func leavesApp(_ tool: String) -> Bool {
        tool == "press_home" || tool == "launch_app" || tool == "open_url"
    }

    func checkLaunch(_ tool: String, arguments: JSONObject) -> Verdict {
        guard tool == "launch_app", let id = arguments["bundle_id"]?.stringValue else { return .allow }
        return launchVerdict(bundleID: id, name: nil)
    }

    /// Whether opening this app is allowed; `launch_app` by name checks the app it resolved to.
    func launchVerdict(bundleID: String, name: String?) -> Verdict {
        let blocked = configuration.blockedApps.map { $0.lowercased() }
        let names = [bundleID, name, AppLookup.name(forBundleID: bundleID)].compactMap { $0?.lowercased() }
        return names.contains(where: blocked.contains)
            ? .block("Opening \(name ?? bundleID) is blocked by the user's safety settings.") : .allow
    }

    var hook: Hook {
        Hook.beforeTool { [self] call, _ in
            if case .block(let message) = checkLaunch(call.name, arguments: call.arguments) { return .block(message) }
            let app = await screen.app
            if case .block(let message) = gate(tool: call.name, app: app) { return .block(message) }
            if needsApproval(tool: call.name, app: app) {
                let action = StepDescriber.intent(call, screen: await screen.screen?.text)
                if case .block(let message) = await approve(tool: call.name, action: action, app: app) { return .block(message) }
            }
            if case .block(let message) = count(tool: call.name) { return .block(message) }
            return .allow
        }
    }
}
