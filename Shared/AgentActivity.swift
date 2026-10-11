import ActivityKit
import AppIntents
import Foundation

/// The agent's run on the Lock Screen and in the Dynamic Island. Compiled into the app and the widget extension.
struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case working, waiting, finished, stopped
        }

        /// A question waiting for the user, with buttons the Live Activity can answer.
        struct Prompt: Codable, Hashable {
            var id: String
            var question: String
            var options: [String]
            /// A typed answer is possible (in the app or the notification), not in the Live Activity.
            var allowsText: Bool
        }

        var phase: Phase
        /// "Tapped “Search”", "Thinking…", or the answer when finished.
        var action: String
        /// The app the agent is in.
        var app: String?
        var steps: Int
        var maxSteps: Int
        var prompt: Prompt?
    }

    /// The user's request.
    var request: String
    var startedAt: Date
}

/// Routes Live Activity buttons to the running app. The intents run in the app's process; the widget extension
/// only renders them.
@MainActor
enum AgentIntentRouter {
    static var answer: ((_ promptID: String, _ reply: String) async -> Void)?
    static var stop: (() async -> Void)?
}

/// Answers the agent's question from a Live Activity button.
struct AnswerPromptIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer the agent"
    static let isDiscoverable = false

    @Parameter(title: "Question") var promptID: String
    @Parameter(title: "Reply") var reply: String

    init() {}

    init(promptID: String, reply: String) {
        self.promptID = promptID
        self.reply = reply
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AgentIntentRouter.answer?(promptID, reply)
        return .result()
    }
}

/// Stops the agent from the Live Activity.
struct StopAgentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the agent"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await AgentIntentRouter.stop?()
        return .result()
    }
}
