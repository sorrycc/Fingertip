import CoreGraphics
import Foundation
import Testing
@testable import AgentCore
import PiDurableKit

@Suite struct ScreenFormatterTests {
    let phone = SimulatedPhone()

    @Test func numbersActionableElements() async throws {
        let rendered = ScreenFormatter(screen: phone.screenSize).render(try await phone.snapshot())
        #expect(rendered.text.hasPrefix("App: Home Screen (com.apple.springboard)"))
        #expect(rendered.text.contains(#"[2] Icon "SkyFares" @(160,120)"#))
        #expect(rendered.elements[2] == CGRect(x: 115, y: 90, width: 90, height: 60))
    }

    @Test func skipsOffscreenAndShowsTextFieldState() {
        let root = UINode(type: ElementType.application, frame: CGRect(x: 0, y: 0, width: 400, height: 800), children: [
            UINode(type: ElementType.button, label: "Hidden", frame: CGRect(x: 0, y: 2000, width: 50, height: 50)),
            UINode(type: ElementType.textField, label: "To", placeholder: "Where to?", frame: CGRect(x: 0, y: 0, width: 400, height: 40), focused: true),
            UINode(type: ElementType.other, frame: .zero, children: [
                UINode(type: ElementType.staticText, label: "Line\n\"two\"", frame: CGRect(x: 0, y: 100, width: 100, height: 20)),
            ]),
        ])
        let rendered = ScreenFormatter(screen: CGSize(width: 400, height: 800)).render(ScreenSnapshot(app: AppInfo(), root: root))
        #expect(!rendered.text.contains("Hidden"))
        #expect(rendered.text.contains(#"[1] TextField "To" value="" placeholder="Where to?" focused @(200,20)"#))
        #expect(rendered.text.contains(#"[2] StaticText "Line 'two'""#))
        #expect(rendered.looksOpaque)
    }

    @Test func parsesDeviceDictionaries() throws {
        let dict: [String: Any] = [
            "type": 9, "label": "OK", "identifier": "", "frame": [1.0, 2.0, 3.0, 4.0],
            "children": [["type": 48, "label": "Hi", "frame": [0.0, 0.0, 1.0, 1.0]]],
        ]
        let node = try #require(UINode(dictionary: dict))
        #expect(node.typeName == "Button")
        #expect(node.identifier == nil)
        #expect(node.frame == CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(node.children.first?.label == "Hi")
    }
}

@Suite struct SafetyPolicyTests {
    @Test func budgetStopAndBlockedApps() {
        let policy = SafetyPolicy(configuration: .init(maxStepsPerRun: 2, blockedApps: ["com.bank.app"]), screen: ScreenState())
        let app = AppInfo(bundleID: "com.example", name: "Example")
        #expect(policy.check(tool: "view_screen", app: app) == .allow)
        #expect(policy.check(tool: "tap", app: app) == .allow)
        #expect(policy.check(tool: "tap", app: app) == .allow)
        #expect(policy.check(tool: "tap", app: app) != .allow)

        policy.beginRun()
        #expect(policy.check(tool: "tap", app: AppInfo(bundleID: "com.bank.app")) != .allow)
        #expect(policy.check(tool: "press_home", app: AppInfo(bundleID: "com.bank.app")) == .allow)
        #expect(policy.checkLaunch("launch_app", arguments: ["bundle_id": "com.bank.app"]) != .allow)

        policy.requestStop()
        #expect(policy.check(tool: "tap", app: app) != .allow)
    }
}

@Suite struct SimulatedPhoneTests {
    @Test func searchFlow() async throws {
        let phone = SimulatedPhone()
        try await phone.tap(CGPoint(x: 160, y: 120))
        try await phone.tap(CGPoint(x: 215, y: 250))
        try await phone.typeText("London\n")
        try await phone.tap(CGPoint(x: 215, y: 420))
        let text = ScreenFormatter(screen: phone.screenSize).render(try await phone.snapshot()).text
        #expect(text.contains("19:20 FR 672, €29"))
        #expect(try await phone.screenshot().count > 100)
    }
}

@Suite struct AgentHostTests {
    @Test func switchesBetweenProvidersAndDropsScreenshotsForTextOnlyModels() async throws {
        let deepSeek = ModelProvider.deepSeek(apiKey: "sk-test")
        let zenMux = ModelProvider(
            id: "fingertip-zenmux", name: "ZenMux", baseURL: URL(string: "https://zenmux.ai/api/anthropic")!,
            apiKey: "sk-test", modelIDs: ["anthropic/claude-sonnet-5.5", "anthropic/claude-haiku-5.5"], supportsImages: false)
        let host = try await AgentHost.open(
            providers: [deepSeek, zenMux], model: "deepseek-flash", of: deepSeek, storage: .memory, driver: SimulatedPhone())

        var agent = try await host.conversation.agent()
        #expect(agent.model == deepSeek.ref("deepseek-flash"))
        #expect(agent.tools.contains(ComputerUse.screenshotTool))

        try await host.select("anthropic/claude-haiku-5.5", of: zenMux)
        agent = try await host.conversation.agent()
        #expect(agent.model == ModelRef(provider: "fingertip-zenmux", modelId: "anthropic/claude-haiku-5.5"))
        #expect(!agent.tools.contains(ComputerUse.screenshotTool))
        #expect(await host.screen.imagesAllowed == false)

        try await host.select("deepseek-flash", of: deepSeek)
        #expect(try await host.conversation.agent().tools.contains(ComputerUse.screenshotTool))
    }
}
