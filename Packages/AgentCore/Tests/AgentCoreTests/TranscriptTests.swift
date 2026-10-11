import Foundation
import PiDurableKit
import Testing
@testable import AgentCore

@Suite struct TranscriptTests {
    static let screen = #"App: Maps (com.apple.Maps)  screen 402x874 points\n[1] Button \"Search Maps\" @(201,800)\n[2] Image @(30,30)"#

    func entry(_ id: Int, _ kind: String, _ message: String) throws -> Entry {
        let json = #"{"id":\#(id),"conversationId":1,"kind":"\#(kind)","model":[\#(message)]}"#
        return try JSONDecoder().decode(Entry.self, from: Data(json.utf8))
    }

    func user(_ id: Int, _ text: String) throws -> Entry {
        try entry(id, "pi.user", #"{"role":"user","content":[{"type":"text","text":"\#(text)"}],"timestamp":1000}"#)
    }

    func assistant(_ id: Int, _ text: String, calls: [(String, String, String)] = [], stop: String = "stop") throws -> Entry {
        var blocks = text.isEmpty ? [] : [#"{"type":"text","text":"\#(text)"}"#]
        blocks += calls.map { #"{"type":"toolCall","id":"\#($0.0)","name":"\#($0.1)","arguments":\#($0.2)}"# }
        return try entry(id, "pi.assistant",
            #"{"role":"assistant","content":[\#(blocks.joined(separator: ","))],"stopReason":"\#(stop)","timestamp":2000}"#)
    }

    func result(_ id: Int, call: String, _ text: String, app: String? = "Maps (com.apple.Maps)", error: Bool = false) throws -> Entry {
        let details = app.map { #","details":{"app":"\#($0)","elements":2}"# } ?? ""
        return try entry(id, "pi.tool-result",
            #"{"role":"toolResult","toolCallId":"\#(call)","toolName":"x","content":[{"type":"text","text":"\#(text)"}],"isError":\#(error),"timestamp":5000,"durationMs":120\#(details)}"#)
    }

    @Test func groupsToolCallsIntoOneActivityWithReadableSteps() throws {
        let entries = [
            try user(1, "Find coffee"),
            try assistant(2, "Opening Maps.", calls: [("a", "launch_app", #"{"bundle_id":"com.apple.Maps"}"#)], stop: "toolUse"),
            try result(3, call: "a", Self.screen),
            try assistant(4, "", calls: [("b", "tap", #"{"element":1}"#), ("c", "type_text", #"{"text":"coffee\n"}"#)], stop: "toolUse"),
            try result(5, call: "b", "Done"),
            try result(6, call: "c", "No field", app: nil, error: true),
            try assistant(7, "Blue Bottle is open."),
        ]
        let transcript = TranscriptBuilder().build(entries: entries, isBusy: false)
        #expect(transcript.items.count == 3)
        #expect(transcript.status == .idle)
        #expect(transcript.lastAnswer == "Blue Bottle is open.")
        guard case .activity(let activity) = transcript.items[1] else { Issue.record("no activity"); return }
        #expect(!activity.isLive)
        #expect(activity.entries.first == .note(id: "2", text: "Opening Maps."))
        #expect(activity.steps.map(\.title) == ["Opened Maps", "Tapped “Search Maps”", "Typed “coffee” and pressed return"])
        #expect(activity.steps.map(\.status) == [.done, .done, .failed])
        #expect(activity.steps[2].detail == "No field")
        #expect(activity.steps[0].duration == .milliseconds(120))
    }

    @Test func liveRunShowsRunningStepAndStatus() throws {
        let entries = [
            try user(1, "Go"),
            try assistant(2, "", calls: [("a", "view_screen", "{}")], stop: "toolUse"),
            try result(3, call: "a", Self.screen),
            try assistant(4, "", calls: [("b", "tap", #"{"element":2}"#)], stop: "toolUse"),
        ]
        let builder = TranscriptBuilder()
        let live = builder.build(entries: entries, isBusy: true)
        guard case .activity(let activity) = live.items.last else { Issue.record("no activity"); return }
        #expect(activity.isLive)
        #expect(activity.steps.map(\.title) == ["Looked at Maps", "Tapped an image"])
        #expect(activity.steps[0].detail == "2 elements")
        #expect(live.status == .acting("Tapped an image"))

        let stopped = builder.build(entries: entries + [try assistant(5, "", stop: "aborted")], isBusy: false)
        #expect(stopped.items.last == .notice(id: "5-stopped", .stopped))
        guard case .activity(let ended) = stopped.items[1] else { Issue.record("no activity"); return }
        #expect(ended.steps.last?.status == .interrupted)
    }

    @Test func askUserShowsAsWaitingThenAnswered() throws {
        let call = [("q", "ask_user", #"{"question":"Send it?","options":["Send","Cancel"]}"#)]
        let entries = [try user(1, "Text Alex"), try assistant(2, "", calls: call, stop: "toolUse")]
        let builder = TranscriptBuilder()
        let waiting = builder.build(entries: entries, isBusy: true)
        #expect(waiting.status == .waitingForUser("Send it?"))

        let answered = try entry(3, "pi.tool-result",
            #"{"role":"toolResult","toolCallId":"q","toolName":"ask_user","content":[{"type":"text","text":"The user replied: Send"}],"isError":false,"timestamp":5000,"details":{"reply":"Send"}}"#)
        let done = builder.build(entries: entries + [answered], isBusy: true)
        guard case .activity(let activity) = done.items.last else { Issue.record("no activity"); return }
        #expect(activity.steps[0].title == "Asked: Send it?")
        #expect(activity.steps[0].detail == "You answered: Send")
        #expect(done.status == .thinking)
    }

    @Test func describesOtherTools() {
        func title(_ name: String, _ args: JSONObject) -> String {
            StepDescriber.describe(ToolCall(id: "x", name: name, arguments: args), result: nil, screen: nil).title
        }
        #expect(title("open_url", ["url": "https://www.apple.com/iphone"]) == "Opened apple.com")
        #expect(title("swipe", ["direction": "up"]) == "Swiped up")
        #expect(title("wait", ["seconds": 1.5]) == "Waited 1.5s")
        #expect(title("tap", ["x": 10, "y": 20.6]) == "Tapped at (10, 20)")
        #expect(title("launch_app", ["bundle_id": "com.ryanair.cheapflights"]) == "Opened Cheapflights")
        #expect(title("press_home", [:]) == "Went to the Home Screen")
    }
}
