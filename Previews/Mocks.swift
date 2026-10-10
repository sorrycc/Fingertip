import AgentCore
import Foundation
import Observation

/// Stand-in for the real `AppModel`, with the same surface the UI uses.
@Observable
@MainActor
final class AppModel {
    private(set) var settings = AgentSettings()
    private(set) var transcript = Transcript()
    private(set) var agentError: String?
    private(set) var isOpening = false
    private(set) var needsRelaunch = false
    private(set) var hasAPIKey = true
    let automation: AutomationSession
    @ObservationIgnored private var run: Task<Void, Never>?

    var isBusy: Bool { transcript.isBusy }

    init(scenario: String) {
        automation = AutomationSession(phase: scenario == "setup" ? .idle : scenario == "starting" ? .starting(.tunnel) : .ready)
        automation.pairingLoaded = scenario != "setup"
        switch scenario {
        case "working":
            transcript = Transcript(items: [Sample.request, .activity(Sample.activity(live: true))], status: .acting("Tapped “Search Maps”"))
        case "done":
            transcript = Transcript(items: [Sample.request, .activity(Sample.activity(live: false)), Sample.answer])
        case "failed":
            automation.phase = .failed("Tunnel failed: connection refused. Is LocalDevVPN connected?")
            transcript = Transcript(items: [Sample.request, .activity(Sample.activity(live: false)), .notice(id: "n", .stopped)])
        default:
            break
        }
    }

    func openAgent() async {}

    func save(_ settings: AgentSettings, apiKey: String) async {
        self.settings = settings
        hasAPIKey = !apiKey.isEmpty
    }

    /// Plays a scripted run so animations can be checked.
    func send(_ text: String) async {
        let base = transcript.items + [.user(id: UUID().uuidString, text: text)]
        transcript = Transcript(items: base, status: .thinking)
        run = Task {
            try? await Task.sleep(for: .seconds(1.2))
            let all = Sample.activity(live: true)
            for count in 1...all.entries.count {
                guard !Task.isCancelled else { return }
                var activity = all
                activity.id = "run-\(base.count)"
                activity.entries = Array(all.entries.prefix(count))
                transcript = Transcript(items: base + [.activity(activity)], status: .acting(activity.steps.last?.title ?? ""))
                try? await Task.sleep(for: .seconds(0.9))
            }
            var done = Sample.activity(live: false)
            done.id = "run-\(base.count)"
            transcript = Transcript(items: base + [.activity(done), Sample.answer])
        }
    }

    func stop() async {
        run?.cancel()
        transcript = Transcript(items: transcript.items + [.notice(id: UUID().uuidString, .stopped)])
    }

    func newTask() async { transcript = Transcript() }
    func dismissError() { agentError = nil }
}

/// Stand-in for the real `AutomationSession`.
@Observable
@MainActor
final class AutomationSession {
    typealias Phase = AutomationPhase
    typealias StartStep = AutomationStartStep

    var phase: Phase
    var pairingLoaded = true
    var heartbeatOK: Bool { phase == .ready }
    var keepAliveActive: Bool { phase == .ready }
    var hasRemotePairing: Bool { pairingLoaded }
    var hasLockdownPairing = true
    var startedAt: Date? = .now.addingTimeInterval(-23)
    @ObservationIgnored let logger = ProtocolLogger()

    static var logURL: URL { URL.documentsDirectory.appending(path: "automation.log") }
    var isReady: Bool { phase == .ready }

    init(phase: Phase) {
        self.phase = phase
        logger.log("Loaded lockdown pairing (HostID: 5E1A…)", phase: "INIT", level: .success)
        logger.log("Local Network permission: granted", phase: "P0")
        logger.log("RemotePairing tunnel + heartbeat up", phase: "P1", level: .success)
        logger.log("dlopen XCTest.framework", phase: "DLOPEN", level: .success)
        logger.log("Heartbeat: device unreachable", phase: "HB", level: .warning)
        logger.log("UI automation ready", phase: "READY", level: .success)
    }

    func importPairing(from url: URL) -> (ok: Bool, message: String) { (true, "RemotePairing file imported") }

    func start() async {
        startedAt = .now
        for step in StartStep.allCases {
            phase = .starting(step)
            try? await Task.sleep(for: .seconds(1.5))
        }
        phase = .ready
    }

    func stop() { phase = .idle }
}

enum Sample {
    static let request = Transcript.Item.user(id: "u1", text: "Open Maps and find the nearest coffee shop that's open now")

    static let answer = Transcript.Item.answer(id: "a1", text: """
        **Blue Bottle Coffee** on Market St is the closest one open right now — about a 4‑minute walk (0.2 mi). \
        It's open until 6 PM.

        Next closest: *Sightglass Coffee*, 7 minutes away, open until 5 PM.
        """, isStreaming: false)

    static func activity(live: Bool) -> Activity {
        var entries: [Activity.Entry] = [
            .note(id: "n1", text: "I'll open Maps and search for coffee nearby."),
            .step(Step(id: "s1", tool: "launch_app", title: "Opened Maps", status: .done, output: "Done: launched com.apple.Maps", duration: .milliseconds(1840))),
            .step(Step(id: "s2", tool: "tap", title: "Tapped “Search Maps”", detail: "in Maps", status: .done, output: "Done: tapped [3] at (201,812)\n\nApp: Maps (com.apple.Maps)  screen 402x874 points\n[1] Button \"Cancel\" @(360,64)\n[2] SearchField \"Search Maps\" value=\"\" focused @(180,64)", duration: .milliseconds(1210))),
            .step(Step(id: "s3", tool: "type_text", title: "Typed “coffee” and pressed return", detail: "in Maps", status: .done, duration: .milliseconds(2380))),
            .step(Step(id: "s4", tool: "view_screen", title: "Looked at Maps", detail: "38 elements", status: .done, duration: .milliseconds(410))),
            .step(Step(id: "s5", tool: "swipe", title: "Swiped up", detail: "No element [12] on the latest screen.", status: .failed, output: "No element [12] on the latest screen.")),
            .step(Step(id: "s6", tool: "tap", title: "Tapped “Open Now”", detail: "in Maps", status: .done, duration: .milliseconds(1020))),
            .step(Step(id: "s7", tool: "screenshot", title: "Took a screenshot", status: .done, duration: .milliseconds(650))),
        ]
        if live {
            entries.append(.step(Step(id: "s8", tool: "tap", title: "Tapped “Blue Bottle Coffee”", detail: "in Maps", status: .running)))
        }
        return Activity(id: "act1", entries: entries, startedAt: .now.addingTimeInterval(-42), endedAt: live ? nil : .now, isLive: live)
    }
}
