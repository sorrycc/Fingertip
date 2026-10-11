import CoreGraphics
import Foundation
import PiDurableKit
import Testing
@testable import AgentCore

/// A driver showing whatever snapshot the test sets, recording what was sent.
actor ScriptedDriver: DeviceDriver {
    nonisolated var screenSize: CGSize { CGSize(width: 400, height: 800) }
    var current: ScreenSnapshot
    var taps: [CGPoint] = []
    var typed: [String] = []
    /// Snapshot shown after the next tap.
    var afterTap: ScreenSnapshot?
    var failTypingAfter: Int?

    init(_ snapshot: ScreenSnapshot) { current = snapshot }

    func show(_ snapshot: ScreenSnapshot) { current = snapshot }
    func setAfterTap(_ snapshot: ScreenSnapshot?) { afterTap = snapshot }
    func setFailTypingAfter(_ count: Int?) { failTypingAfter = count }

    func snapshot() async throws -> ScreenSnapshot { current }
    func screenshot() async throws -> Data { Data() }
    func tap(_ point: CGPoint) async throws {
        taps.append(point)
        if let next = afterTap { current = next; afterTap = nil }
    }
    func longPress(_ point: CGPoint, duration: TimeInterval) async throws {}
    func swipe(from: CGPoint, to: CGPoint, duration: TimeInterval) async throws {}
    func typeText(_ text: String) async throws {
        if let limit = failTypingAfter, typed.count >= limit { throw DriverError("connection lost") }
        typed.append(text)
    }
    func pressHome() async throws {}
    func launchApp(bundleID: String) async throws {}
    func openURL(_ url: URL) async throws {}
}

func node(_ type: Int, _ label: String? = nil, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
          id: String? = nil, value: String? = nil, focused: Bool = false, _ children: [UINode] = []) -> UINode {
    UINode(type: type, label: label, identifier: id, value: value, frame: CGRect(x: x, y: y, width: w, height: h),
           focused: focused, children: children)
}

func app(_ children: [UINode], alert: UINode? = nil, bundle: String = "com.example.app") -> ScreenSnapshot {
    ScreenSnapshot(
        app: AppInfo(bundleID: bundle, name: "Example"),
        root: node(ElementType.application, nil, 0, 0, 400, 800, children), alert: alert)
}

func args(_ json: String) throws -> ComputerUse.Tools.ActionArgs {
    try JSONDecoder().decode(ComputerUse.Tools.ActionArgs.self, from: Data(json.utf8))
}

let fast = ComputerUseOptions(settle: SettleOptions(minimumWait: .zero, interval: .milliseconds(1), budget: .milliseconds(200)))

func tools(_ driver: any DeviceDriver, policy: SafetyPolicy.Configuration = .init()) -> ComputerUse.Tools {
    let state = ScreenState()
    return ComputerUse.Tools(
        driver: driver, state: state, policy: SafetyPolicy(configuration: policy, screen: state), options: fast)
}

extension ToolResult {
    var joinedText: String { content?.compactMap(\.text).joined() ?? "" }
}

@Suite struct ScreenModelTests {
    let formatter = ScreenFormatter(screen: CGSize(width: 400, height: 800))

    @Test func keepsNumbersAcrossReadsAndNumbersNewElementsFresh() {
        let first = formatter.render(app([
            node(ElementType.button, "A", 0, 100, 100, 40), node(ElementType.button, "B", 0, 200, 100, 40),
        ]))
        #expect(first.items[1]?.label == "A" && first.items[2]?.label == "B")
        let second = formatter.render(app([
            node(ElementType.button, "New", 0, 50, 100, 40),
            node(ElementType.button, "B", 0, 200, 100, 40),
        ]), previous: first)
        #expect(second.items[2]?.label == "B")
        #expect(second.items[3]?.label == "New")
        #expect(second.items[1] == nil)
        // Another app starts over.
        let other = formatter.render(app([node(ElementType.button, "B", 0, 200, 100, 40)], bundle: "com.other"), previous: second)
        #expect(other.items[1]?.label == "B")
    }

    @Test func leavesOutDecoration() {
        let rendered = formatter.render(app([
            node(ElementType.navigationBar, "Settings", 0, 0, 400, 90),
            node(ElementType.staticText, "Settings", 0, 100, 400, 40),
            node(ElementType.button, "Wi-Fi, On", 0, 200, 400, 44, [
                node(ElementType.staticText, "Wi-Fi", 10, 200, 100, 44),
                node(ElementType.image, "chevron.forward", 380, 210, 10, 20),
            ]),
            node(ElementType.cell, nil, 0, 300, 400, 60, [
                node(ElementType.staticText, "Ryanair", 10, 300, 100, 30),
                node(ElementType.staticText, "€29", 300, 300, 100, 30),
            ]),
            node(ElementType.button, "Edit", 0, 400, 100, 40, id: "edit-top"),
            node(ElementType.button, "Edit", 0, 500, 100, 40, id: "edit-bottom"),
        ]))
        let text = rendered.text
        #expect(text.components(separatedBy: "\"Settings\"").count == 2)
        #expect(!text.contains("chevron"))
        #expect(!text.contains("StaticText \"Wi-Fi\""))
        #expect(text.contains(#"Cell "Ryanair · €29""#))
        #expect(!text.contains("StaticText \"€29\""))
        #expect(text.contains(#"id="edit-top""#) && text.contains(#"id="edit-bottom""#))
    }

    @Test func showsSystemAlertsAndKeyboard() {
        let alert = node(ElementType.alert, "Allow “Maps” to use your location?", 50, 300, 300, 200, [
            node(ElementType.staticText, "Allow “Maps” to use your location?", 60, 310, 280, 40),
            node(ElementType.button, "Allow Once", 60, 400, 280, 40),
            node(ElementType.button, "Don’t Allow", 60, 450, 280, 40),
        ])
        let rendered = formatter.render(app([
            node(ElementType.textField, "Search", 0, 100, 400, 40, focused: true),
            node(ElementType.keyboard, nil, 0, 500, 400, 300),
        ], alert: alert))
        #expect(rendered.alert?.isSystem == true)
        #expect(rendered.alert?.buttons == ["Allow Once", "Don’t Allow"])
        #expect(rendered.header.contains("keyboard: up"))
        #expect(rendered.header.contains("System alert on screen"))
        #expect(rendered.keyboardFrame == CGRect(x: 0, y: 500, width: 400, height: 300))
    }

    @Test func findsAKeyboardWithoutAKeyboardElement() {
        let rendered = formatter.render(app([
            node(ElementType.searchField, "Search Actions", 20, 80, 320, 40),
            node(ElementType.other, nil, 0, 500, 400, 260, id: "inputView"),
            node(ElementType.button, "Dictate", 340, 760, 40, 40, id: "dictation"),
        ]))
        #expect(rendered.header.contains("keyboard: up"))
        #expect(rendered.keyboardFrame == CGRect(x: 0, y: 500, width: 400, height: 300))
    }

    @Test func deltaListsOnlyChanges() {
        let before = formatter.render(app([
            node(ElementType.textField, "To", 0, 100, 400, 40),
            node(ElementType.button, "Cancel", 0, 200, 100, 40),
            node(ElementType.button, "Search", 0, 300, 100, 40),
        ]))
        let after = formatter.render(app([
            node(ElementType.textField, "To", 0, 100, 400, 40, value: "London"),
            node(ElementType.button, "Search", 0, 300, 100, 40),
            node(ElementType.staticText, "3 results", 0, 400, 100, 40),
        ]), previous: before)
        let changes = ScreenDelta.changes(from: before, to: after)
        #expect(changes.changed == [#"~ [1] TextField "To" value="London" @(200,120)"#])
        #expect(changes.removed == [#"- [2] Button "Cancel" @(50,220)"#])
        #expect(changes.added == [#"+ [4] StaticText "3 results" @(50,420)"#])
    }
}

@Suite struct TapPlannerTests {
    let formatter = ScreenFormatter(screen: CGSize(width: 400, height: 800))

    @Test func tapsTheUncoveredPartOfARowUnderAFloatingSearchField() throws {
        let screen = formatter.render(app([
            node(ElementType.cell, "General", 0, 700, 400, 60),
            node(ElementType.searchField, "Search", 20, 730, 360, 50),
        ]))
        let plan = try #require(TapPlanner.plan(1, in: screen))
        guard case .shifted(let point, let cover) = plan else { Issue.record("expected shifted, got \(plan)"); return }
        #expect(point.y < 716 && point.y >= 700)
        #expect(cover.contains("Search"))
        #expect(TapPlanner.plan(2, in: screen) == .center(CGPoint(x: 200, y: 755)))
    }

    @Test func refusesARowFullyUnderABar() {
        let screen = formatter.render(app([
            node(ElementType.navigationBar, "Title", 0, 0, 400, 100),
            node(ElementType.cell, "Hidden row", 0, 20, 400, 60),
        ]))
        #expect(TapPlanner.plan(1, in: screen) == .covered(by: "NavigationBar “Title”"))
    }

    @Test func anActiveSearchFieldIsOnTopOfTheNavigationBar() {
        let screen = formatter.render(app([
            node(ElementType.navigationBar, "New Shortcut", 0, 50, 400, 70),
            node(ElementType.searchField, "Search Actions", 20, 80, 320, 40),
        ]))
        #expect(TapPlanner.plan(1, in: screen) == .center(CGPoint(x: 180, y: 100)))
    }

    @Test func barItemsAreOnTopOfContent() {
        let screen = formatter.render(app([
            node(ElementType.button, "Big content button", 0, 700, 400, 80),
            node(ElementType.tabBar, nil, 0, 720, 400, 80, [node(ElementType.button, "Home", 0, 720, 100, 80)]),
        ]))
        let home = screen.items.values.first { $0.label == "Home" }!
        #expect(TapPlanner.plan(home.number, in: screen) == .center(CGPoint(x: 50, y: 760)))
    }

    @Test func alertsCoverTheAppBehindThem() {
        let screen = formatter.render(app(
            [node(ElementType.button, "Behind", 0, 100, 100, 40)],
            alert: node(ElementType.alert, nil, 50, 300, 300, 200, [node(ElementType.button, "OK", 60, 400, 280, 40)])))
        let behind = screen.items.values.first { $0.label == "Behind" }!
        let ok = screen.items.values.first { $0.label == "OK" }!
        guard case .covered = TapPlanner.plan(behind.number, in: screen) else { Issue.record("not covered"); return }
        #expect(TapPlanner.plan(ok.number, in: screen) == .center(CGPoint(x: 200, y: 420)))
    }
}

@Suite struct LookupTests {
    @Test func findsAppsByNameInAnyLanguage() {
        #expect(AppLookup.resolve("微信", installed: [])?.bundleID == "com.tencent.xin")
        #expect(AppLookup.resolve("wechat", installed: [])?.bundleID == "com.tencent.xin")
        #expect(AppLookup.resolve("Settings", installed: [])?.bundleID == "com.apple.Preferences")
        #expect(AppLookup.resolve("设置", installed: [])?.bundleID == "com.apple.Preferences")
        let installed = [InstalledApp(bundleID: "com.example.skyfares", name: "SkyFares")]
        #expect(AppLookup.resolve("skyfares", installed: installed)?.bundleID == "com.example.skyfares")
        #expect(AppLookup.find("WeChat", installed: installed).first?.installed == false)
        // A partial name is not launched without a choice.
        #expect(AppLookup.resolve("Google", installed: [])?.bundleID == "com.google.GoogleMobile")
        #expect(AppLookup.resolve("Goog", installed: []) == nil)
        #expect(AppLookup.find("Goog", installed: []).count > 1)
    }

    @Test func chunksNeverSplitCharacters() {
        let text = String(repeating: "a", count: 199) + "👩‍👩‍👧" + "🇮🇪b"
        let chunks = TextChunks.split(text, size: 200)
        #expect(chunks == [String(repeating: "a", count: 199) + "👩‍👩‍👧", "🇮🇪b"])
        #expect(TextChunks.split("hi", size: 200) == ["hi"])
    }
}

@Suite struct ToolTests {
    @Test func searchFlowWithLabelsDeltasAndABatch() async throws {
        let phone = SimulatedPhone()
        let tools = tools(phone)
        _ = try await tools.freshScreen()

        let launched = try await tools.runAction("launch_app", try args(#"{"app":"SkyFares"}"#)).joinedText
        #expect(launched.contains("launched SkyFares (com.example.skyfares)"))
        #expect(launched.contains("Foreground app changed"))
        #expect(launched.contains(#"TextField "To""#))

        // Typing with nothing focused sends nothing.
        await #expect(throws: DriverError.self) { try await tools.runAction("type_text", try args(#"{"text":"London"}"#)) }

        let tapped = try await tools.runAction("tap", try args(#"{"label":"To"}"#)).joinedText
        #expect(tapped.contains("Changes since the last screen"))
        #expect(tapped.contains("keyboard: up"))

        let batch = try await tools.batch([
            try args(#"{"action":"type_text","text":"Londom"}"#),
            try args(#"{"action":"press_key","key":"delete"}"#),
            try args(#"{"action":"type_text","text":"n\n"}"#),
            try args(#"{"action":"tap","label":"Search flights"}"#),
            try args(#"{"action":"wait_for","present":["€29"]}"#),
        ]).joinedText
        #expect(batch.contains("Ran all 5 steps"))
        #expect(batch.contains("19:20 FR 672, €29"))
        #expect(batch.contains("Dublin → London"))
    }

    @Test func saysWhenNothingChangedAndAdvisesAfterTwice() async throws {
        let driver = ScriptedDriver(app([node(ElementType.button, "Inert", 0, 100, 100, 40)]))
        let tools = tools(driver)
        _ = try await tools.freshScreen()
        let once = try await tools.runAction("tap", try args(#"{"element":1}"#)).joinedText
        #expect(once.contains("The screen did not change."))
        #expect(!once.contains("times in a row"))
        let twice = try await tools.runAction("tap", try args(#"{"element":1}"#)).joinedText
        #expect(twice.contains("2 times in a row"))
    }

    @Test func refusesCoveredTargetsAndAmbiguousLabels() async throws {
        let driver = ScriptedDriver(app([
            node(ElementType.navigationBar, "Title", 0, 0, 400, 100),
            node(ElementType.cell, "Under", 0, 20, 400, 60),
            node(ElementType.button, "Same", 0, 200, 100, 40),
            node(ElementType.button, "Same", 0, 300, 100, 40),
        ]))
        let tools = tools(driver)
        _ = try await tools.freshScreen()
        await #expect(throws: DriverError.self) { try await tools.runAction("tap", try args(#"{"label":"Under"}"#)) }
        do {
            _ = try await tools.runAction("tap", try args(#"{"label":"Same"}"#))
            Issue.record("expected ambiguity")
        } catch {
            #expect(error.localizedDescription.contains("2 elements are labeled"))
        }
        do {
            _ = try await tools.runAction("tap", try args(#"{"label":"Sam"}"#))
            Issue.record("expected not found")
        } catch {
            #expect(error.localizedDescription.contains("Did you mean"))
        }
        #expect(await driver.taps.isEmpty)
    }

    @Test func answersSystemAlertsAndNoticesWhenTheyStay() async throws {
        let alert = node(ElementType.alert, nil, 50, 300, 300, 200, [
            node(ElementType.staticText, "Allow notifications?", 60, 310, 280, 40),
            node(ElementType.button, "Allow", 60, 400, 280, 40),
        ])
        let driver = ScriptedDriver(app([node(ElementType.button, "Behind", 0, 100, 100, 40)], alert: alert))
        let tools = tools(driver)
        let stuck = try await tools.runAction("answer_alert", try args(#"{"button":"allow"}"#)).joinedText
        #expect(stuck.contains("answered the alert with Button “Allow”"))
        #expect(stuck.contains("The alert is still showing"))
        #expect(await driver.taps == [CGPoint(x: 200, y: 420)])

        await driver.setAfterTap(app([node(ElementType.button, "Behind", 0, 100, 100, 40)]))
        let gone = try await tools.runAction("answer_alert", try args(#"{"button":"Allow"}"#)).joinedText
        #expect(!gone.contains("still showing"))
    }

    @Test func reportsPartialTypingWithoutRetypingIt() async throws {
        let driver = ScriptedDriver(app([node(ElementType.textView, "Body", 0, 100, 400, 400, focused: true)]))
        await driver.setFailTypingAfter(1)
        let tools = tools(driver)
        _ = try await tools.freshScreen()
        let text = String(repeating: "x", count: 250)
        do {
            _ = try await tools.runAction("type_text", try args(#"{"text":"\#(text)"}"#))
            Issue.record("expected failure")
        } catch {
            #expect(error.localizedDescription.contains("Typing stopped after 200 of 250 characters"))
        }
    }

    @Test func secureFieldsAreNotEchoed() async throws {
        let driver = ScriptedDriver(app([node(ElementType.secureTextField, "Password", 0, 100, 400, 40, focused: true)]))
        let tools = tools(driver)
        _ = try await tools.freshScreen()
        let result = try await tools.runAction("type_text", try args(#"{"text":"hunter2"}"#))
        #expect(!result.joinedText.contains("hunter2"))
        #expect(result.details?["secure"] == .bool(true))
    }

    @Test func blockedAppsAreBlockedByNameAndInBatches() async throws {
        let phone = SimulatedPhone()
        let tools = tools(phone, policy: .init(maxStepsPerRun: 10, blockedApps: ["com.apple.Passbook"]))
        do {
            _ = try await tools.runAction("launch_app", try args(#"{"app":"Wallet"}"#))
            Issue.record("expected block")
        } catch {
            #expect(error.localizedDescription.contains("blocked"))
        }
        let batch = try await tools.batch([try args(#"{"action":"launch_app","bundle_id":"com.apple.Passbook"}"#)]).joinedText
        #expect(batch.contains("was blocked"))
    }

    @Test func waitForTimesOutWithAReason() async throws {
        let tools = tools(SimulatedPhone())
        let outcome = try await tools.waitCondition(try args(#"{"present":["Nowhere"],"timeout":0.5}"#))
        #expect(!outcome.met)
        #expect(outcome.summary.contains("not on screen: “Nowhere”"))
    }
}
