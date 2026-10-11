import Foundation
import os
import PiDurableKit

/// Guards the computer-use actions: a per-run step budget, a stop switch, and apps the agent may not touch.
public final class SafetyPolicy: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Device actions allowed per user request.
        public var maxStepsPerRun: Int
        /// Bundle ids (or app names) where actions are blocked.
        public var blockedApps: [String]

        public init(maxStepsPerRun: Int = 60, blockedApps: [String] = Configuration.defaultBlockedApps) {
            self.maxStepsPerRun = maxStepsPerRun
            self.blockedApps = blockedApps
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

    public init(configuration: Configuration = .init(), screen: ScreenState) {
        state = OSAllocatedUnfairLock(initialState: State(configuration: configuration))
        self.screen = screen
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

    /// Blocks every further action until the next `beginRun()`.
    public func requestStop() {
        state.withLock { $0.stopped = true }
    }

    enum Verdict: Equatable {
        case allow
        case block(String)
    }

    func check(tool: String, app: AppInfo) -> Verdict {
        guard ComputerUse.actionTools.contains(tool) else { return .allow }
        return state.withLock { state in
            if state.stopped {
                return .block("The user pressed Stop. Do not take any more actions; summarize what you did and what is left.")
            }
            let blocked = state.configuration.blockedApps.map { $0.lowercased() }
            let current = [app.bundleID, app.name].compactMap { $0?.lowercased() }
            if tool != "press_home", tool != "launch_app", tool != "open_url", current.contains(where: blocked.contains) {
                return .block("Actions in \(app.display) are blocked by the user's safety settings. Leave this app (press_home) or stop.")
            }
            state.steps += 1
            if state.steps > state.configuration.maxStepsPerRun {
                return .block("Step budget of \(state.configuration.maxStepsPerRun) actions for this request is used up. Stop and report progress to the user.")
            }
            return .allow
        }
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
            if case .block(let message) = check(tool: call.name, app: await screen.app) { return .block(message) }
            return .allow
        }
    }
}
