import Foundation
import PiDurableKit

/// What the chat shows: the conversation's entries folded into user requests, the agent's on-device work
/// (grouped into activities of readable steps), and its answers.
public struct Transcript: Sendable, Equatable {
    public enum Item: Sendable, Equatable, Identifiable {
        case user(id: String, text: String)
        case activity(Activity)
        case answer(id: String, text: String, isStreaming: Bool)
        case notice(id: String, Notice)

        public var id: String {
            switch self {
            case .user(let id, _), .answer(let id, _, _), .notice(let id, _): id
            case .activity(let activity): activity.id
            }
        }
    }

    public enum Notice: Sendable, Equatable {
        case stopped
        case error(String)
    }

    /// What the agent is doing right now.
    public enum Status: Sendable, Equatable {
        case idle
        case thinking
        case acting(String)
        /// The agent asked the user (`ask_user`) and waits for the reply.
        case waitingForUser(String)
        case retrying(at: Date, error: String)
    }

    public var items: [Item] = []
    public var status = Status.idle

    public var isBusy: Bool { status != .idle }
    public var isEmpty: Bool { items.isEmpty }

    public init(items: [Item] = [], status: Status = .idle) {
        self.items = items
        self.status = status
    }

    /// "Maps" for `com.apple.Maps`, for the bundle ids the agent commonly uses.
    public static func appName(forBundleID bundleID: String) -> String? { StepDescriber.knownApps[bundleID] }

    /// The last answer, for the "finished" notification.
    public var lastAnswer: String? {
        for item in items.reversed() {
            if case .answer(_, let text, false) = item { return text }
        }
        return nil
    }
}

/// A run of consecutive tool-using turns.
public struct Activity: Sendable, Equatable, Identifiable {
    public enum Entry: Sendable, Equatable, Identifiable {
        /// What the model said between actions.
        case note(id: String, text: String)
        case step(Step)

        public var id: String {
            switch self {
            case .note(let id, _): id
            case .step(let step): step.id
            }
        }
    }

    public var id: String
    public var entries: [Entry]
    public var startedAt: Date
    public var endedAt: Date?
    public var isLive: Bool

    public init(id: String, entries: [Entry], startedAt: Date, endedAt: Date? = nil, isLive: Bool = false) {
        self.id = id
        self.entries = entries
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isLive = isLive
    }

    public var steps: [Step] {
        entries.compactMap { if case .step(let step) = $0 { step } else { nil } }
    }
}

/// One tool call, described for people.
public struct Step: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        case running, done, failed, interrupted
    }

    public var id: String
    public var tool: String
    /// "Tapped “Search”", "Opened Maps", …
    public var title: String
    /// A short secondary line: the app it looked at, or the error.
    public var detail: String?
    public var status: Status
    /// The raw tool output, shown when expanded.
    public var output: String?
    /// Base64 JPEG/PNG attached to the result (screenshots). Decoded only when shown.
    public var imageBase64: String?
    public var duration: Duration?

    /// The question of an `ask_user` step.
    public var question: String? {
        guard tool == ComputerUse.askUserTool, title.hasPrefix(StepDescriber.askedPrefix) else { return nil }
        return String(title.dropFirst(StepDescriber.askedPrefix.count))
    }

    public init(
        id: String, tool: String, title: String, detail: String? = nil, status: Status, output: String? = nil,
        imageBase64: String? = nil, duration: Duration? = nil
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.detail = detail
        self.status = status
        self.output = output
        self.imageBase64 = imageBase64
        self.duration = duration
    }
}

/// Builds transcripts incrementally. Finished steps are cached by call id, so each update only describes new calls.
public final class TranscriptBuilder {
    private var finished: [String: Step] = [:]

    public init() {}

    public func build(_ view: ConversationView) -> Transcript {
        build(entries: view.entries, isBusy: view.isBusy, streaming: view.streamingMessage, retry: view.live.generation?.retry)
    }

    func build(entries: [Entry], isBusy: Bool, streaming: AssistantMessage? = nil, retry: LiveState.Retry? = nil) -> Transcript {
        var results: [String: ToolResultMessage] = [:]
        for entry in entries {
            if let result = entry.toolResult { results[result.toolCallId] = result }
        }

        var items: [Transcript.Item] = []
        var activity: Activity?
        /// Recent results that ended on a screen, newest last. Actions often return only what changed, so an
        /// element's label may be on an earlier screen. Their text is joined only when an uncached call needs it.
        var screens: [ToolResultMessage] = []
        var running: Step?

        func close() {
            guard var open = activity else { return }
            open.isLive = false
            items.append(.activity(open))
            activity = nil
        }

        for entry in entries {
            switch entry.message {
            case .user(let message):
                close()
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { items.append(.user(id: entry.id.description, text: text)) }

            case .assistant(let message):
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.toolCalls.isEmpty {
                    close()
                    if !text.isEmpty { items.append(.answer(id: entry.id.description, text: text, isStreaming: false)) }
                } else {
                    if activity == nil {
                        activity = Activity(
                            id: entry.id.description, entries: [], startedAt: message.timestamp, endedAt: nil, isLive: false)
                    }
                    if !text.isEmpty { activity?.entries.append(.note(id: entry.id.description, text: text)) }
                    for call in message.toolCalls {
                        let result = results[call.id]
                        let step = describe(call, result: result, screens: screens, isBusy: isBusy)
                        if step.status == .running { running = step }
                        activity?.entries.append(.step(step))
                        if let result {
                            activity?.endedAt = result.timestamp
                            if Self.showsScreen(result) {
                                screens.append(result)
                                if screens.count > 6 { screens.removeFirst() }
                            }
                        }
                    }
                }
                if message.stopReason == .aborted {
                    close()
                    items.append(.notice(id: "\(entry.id)-stopped", .stopped))
                } else if let error = message.errorMessage, message.stopReason == .error {
                    close()
                    items.append(.notice(id: "\(entry.id)-error", .error(error)))
                }

            default:
                continue
            }
        }

        let streamingText = streaming?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isBusy, streamingText.isEmpty, activity != nil {
            activity?.isLive = true
            items.append(.activity(activity!))
            activity = nil
        }
        close()
        if isBusy, !streamingText.isEmpty {
            items.append(.answer(id: "streaming", text: streamingText, isStreaming: true))
        }

        let status: Transcript.Status
        if !isBusy {
            status = .idle
        } else if let retry {
            status = .retrying(at: retry.at, error: retry.error)
        } else if let running, running.tool == ComputerUse.askUserTool {
            status = .waitingForUser(running.question ?? running.title)
        } else if let running {
            status = .acting(running.title)
        } else {
            status = .thinking
        }
        return Transcript(items: items, status: status)
    }

    private func describe(_ call: ToolCall, result: ToolResultMessage?, screens: [ToolResultMessage], isBusy: Bool) -> Step {
        if result != nil, let cached = finished[call.id] { return cached }
        let screen = screens.isEmpty ? nil : screens.reversed().map(\.text).joined(separator: "\n")
        let description = StepDescriber.describe(call, result: result, screen: screen)
        guard let result else {
            return Step(id: call.id, tool: call.name, title: description.title, status: isBusy ? .running : .interrupted)
        }
        let image = result.content.lazy.compactMap { block -> String? in
            if case .image(let image) = block { return image.data }
            return nil
        }.first
        let output = result.text
        let step = Step(
            id: call.id, tool: call.name, title: description.title,
            detail: result.isError ? StepDescriber.firstLine(output) : description.detail,
            status: result.isError ? .failed : .done,
            output: output.isEmpty ? nil : output, imageBase64: image, duration: result.duration)
        finished[call.id] = step
        return step
    }

    /// Tool results that end with a fresh screen (observations and actions with `observeAfterActions`).
    private static func showsScreen(_ result: ToolResultMessage) -> Bool {
        !result.isError && result.details?["app"] != nil
    }
}

/// Turns tool calls into short, past-tense descriptions.
enum StepDescriber {
    struct Description: Equatable {
        var title: String
        var detail: String?
    }

    static func describe(_ call: ToolCall, result: ToolResultMessage?, screen: String?) -> Description {
        let args = call.arguments
        let app = result?.details?["app"]?.stringValue.map(appName)
        switch call.name {
        case "view_screen":
            return Description(title: app.map { "Looked at \($0)" } ?? "Looked at the screen", detail: elementCount(result))
        case "screenshot":
            return Description(title: "Took a screenshot")
        case "tap":
            return Description(title: "Tapped \(target(args, result: result, screen: screen))", detail: app.map { "in \($0)" })
        case "long_press":
            return Description(title: "Touched and held \(target(args, result: result, screen: screen))", detail: app.map { "in \($0)" })
        case "type_text":
            if result?.details?["secure"] == .bool(true) {
                return Description(title: "Typed into a secure field", detail: app.map { "in \($0)" })
            }
            var text = args["text"]?.stringValue ?? ""
            let submits = text.hasSuffix("\n")
            if submits { text.removeLast() }
            let typed = text.isEmpty ? "Pressed return" : "Typed \(quoted(text))"
            return Description(title: submits && !text.isEmpty ? "\(typed) and pressed return" : typed, detail: app.map { "in \($0)" })
        case "press_key":
            let key = args["key"]?.stringValue ?? "a key"
            let count = args["count"]?.doubleValue.map(Int.init) ?? 1
            return Description(title: "Pressed \(key)" + (count > 1 ? " ×\(count)" : ""), detail: app.map { "in \($0)" })
        case "back":
            return Description(title: "Went back", detail: app.map { "in \($0)" })
        case "dismiss_keyboard":
            return Description(title: "Hid the keyboard", detail: app.map { "in \($0)" })
        case "answer_alert":
            return Description(title: "Answered an alert: \(quoted(args["button"]?.stringValue ?? ""))")
        case "find_app":
            return Description(title: "Looked up \(quoted(args["name"]?.stringValue ?? "an app"))")
        case "wait_for":
            return Description(title: "Waited for the screen", detail: app.map { "in \($0)" })
        case "run_steps":
            let count = args["steps"]?.arrayValue?.count ?? 0
            return Description(title: count == 1 ? "Ran 1 step" : "Ran \(count) steps", detail: app.map { "in \($0)" })
        case "swipe":
            let direction = args["direction"]?.stringValue
            return Description(title: direction.map { "Swiped \($0)" } ?? "Swiped", detail: app.map { "in \($0)" })
        case "press_home":
            return Description(title: "Went to the Home Screen")
        case "launch_app":
            let bundleID = args["bundle_id"]?.stringValue ?? result?.details?["bundle_id"]?.stringValue ?? ""
            let name = knownApps[bundleID] ?? args["app"]?.stringValue ?? app ?? fallbackName(bundleID)
            return Description(title: "Opened \(name)")
        case "open_url":
            let raw = args["url"]?.stringValue ?? ""
            let url = URL(string: raw)
            let shown = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? raw
            return Description(title: "Opened \(shown.isEmpty ? "a link" : shown)", detail: app.map { "in \($0)" })
        case ComputerUse.askUserTool:
            let reply = result?.details?["reply"]?.stringValue
            return Description(
                title: askedPrefix + (args["question"]?.stringValue ?? "a question"),
                detail: reply.map { "You answered: \($0)" })
        case "wait":
            let seconds = args["seconds"]?.doubleValue ?? 2
            return Description(title: "Waited \(seconds.formatted(.number.precision(.fractionLength(0...1))))s")
        default:
            return Description(title: call.name.replacingOccurrences(of: "_", with: " ").capitalizedFirst)
        }
    }

    static let askedPrefix = "Asked: "

    /// What an action is about to do, in the present tense ("tap “Send”", "open example.com/pay"), for approval
    /// questions.
    static func intent(_ call: ToolCall, screen: String?) -> String {
        let args = call.arguments
        switch call.name {
        case "tap":
            return "tap \(target(args, screen: screen))"
        case "long_press":
            return "touch and hold \(target(args, screen: screen))"
        case "type_text":
            var text = args["text"]?.stringValue ?? ""
            let submits = text.hasSuffix("\n")
            if submits { text.removeLast() }
            if text.isEmpty { return "press return" }
            return "type \(quoted(text))" + (submits ? " and press return" : "")
        case "press_key":
            return "press \(args["key"]?.stringValue ?? "a key")"
        case "swipe":
            return args["direction"]?.stringValue.map { "swipe \($0)" } ?? "swipe"
        case "back":
            return "go back"
        case "dismiss_keyboard":
            return "hide the keyboard"
        case "answer_alert":
            return "answer an alert with \(quoted(args["button"]?.stringValue ?? ""))"
        case "press_home":
            return "go to the Home Screen"
        case "launch_app":
            let bundleID = args["bundle_id"]?.stringValue ?? ""
            return "open \(knownApps[bundleID] ?? args["app"]?.stringValue ?? fallbackName(bundleID))"
        case "open_url":
            return "open \(args["url"]?.stringValue ?? "a link")"
        default:
            return call.name.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// `“Search”` for an element on the screen the model saw, else the coordinates.
    static func target(_ args: JSONObject, result: ToolResultMessage? = nil, screen: String?) -> String {
        if let target = result?.details?["target"]?.stringValue { return quoted(target) }
        if let label = args["label"]?.stringValue { return quoted(label) }
        if let number = args["element"]?.doubleValue.map(Int.init) {
            if let label = label(of: number, in: screen) { return label }
            return "element \(number)"
        }
        if let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue { return "at (\(Int(x)), \(Int(y)))" }
        return "the screen"
    }

    /// Reads `[7] Button "Search" @(…)` from a rendered screen without parsing the whole tree.
    static func label(of element: Int, in screen: String?) -> String? {
        guard let screen, let start = screen.range(of: "[\(element)] ") else { return nil }
        let line = screen[start.upperBound...].prefix { $0 != "\n" }
        if let open = line.firstIndex(of: "\""), let close = line[line.index(after: open)...].firstIndex(of: "\"") {
            let text = line[line.index(after: open)..<close]
            if !text.isEmpty { return quoted(String(text)) }
        }
        let type = line.prefix { $0 != " " }
        guard !type.isEmpty else { return nil }
        let noun = splitCamelCase(String(type)).lowercased()
        return ("aeiou".contains(noun.first ?? "x") ? "an " : "a ") + noun
    }

    static func appName(_ display: String) -> String {
        if let paren = display.range(of: " (") { return String(display[..<paren.lowerBound]) }
        return knownApps[display] ?? display
    }

    static func fallbackName(_ bundleID: String) -> String {
        guard let last = bundleID.split(separator: ".").last, !last.isEmpty else { return "an app" }
        return String(last).capitalizedFirst
    }

    static func elementCount(_ result: ToolResultMessage?) -> String? {
        guard let count = result?.details?["elements"]?.doubleValue else { return nil }
        return count == 1 ? "1 element" : "\(Int(count)) elements"
    }

    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return "“\(flat.count > 40 ? flat.prefix(40) + "…" : flat)”"
    }

    private static func splitCamelCase(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        return out
    }

    static let knownApps: [String: String] = [
        "com.apple.mobilesafari": "Safari", "com.apple.Maps": "Maps", "com.apple.MobileSMS": "Messages",
        "com.apple.mobilemail": "Mail", "com.apple.mobilenotes": "Notes", "com.apple.reminders": "Reminders",
        "com.apple.mobilecal": "Calendar", "com.apple.Preferences": "Settings", "com.apple.AppStore": "App Store",
        "com.apple.Music": "Music", "com.apple.camera": "Camera", "com.apple.mobileslideshow": "Photos",
        "com.apple.springboard": "Home Screen", "com.apple.weather": "Weather", "com.apple.mobiletimer": "Clock",
        "com.apple.calculator": "Calculator", "com.apple.podcasts": "Podcasts", "com.apple.news": "News",
        "com.apple.shortcuts": "Shortcuts", "com.apple.DocumentsApp": "Files", "com.apple.MobileAddressBook": "Contacts",
        "com.apple.Health": "Health", "com.apple.Passbook": "Wallet", "com.apple.stocks": "Stocks",
        "com.apple.tv": "TV", "com.apple.Home": "Home", "com.apple.findmy": "Find My", "com.apple.facetime": "FaceTime",
        "com.apple.mobilephone": "Phone", "com.apple.Translate": "Translate", "com.apple.VoiceMemos": "Voice Memos",
    ]
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
