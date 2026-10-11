import Foundation
import PiDurableKit
import Testing
@testable import AgentCore

/// Waits for the next pending prompt.
func nextPrompt(_ prompts: UserPrompts) async -> UserPrompt? {
    for await prompt in prompts.updates() {
        if let prompt { return prompt }
    }
    return nil
}

@Suite struct UserPromptTests {
    @Test func answerResumesTheAsker() async {
        let prompts = UserPrompts()
        async let reply = prompts.ask(UserPrompt(question: "Send?", options: ["Send", "Cancel"], allowsText: false, source: .model))
        let pending = await nextPrompt(prompts)
        #expect(pending?.question == "Send?")
        #expect(prompts.answer(id: "nope", "Send") == false)
        #expect(prompts.answer(id: pending!.id, "Send"))
        #expect(await reply == .answered("Send"))
        #expect(prompts.pending == nil)
    }

    @Test func cancelAllAndTaskCancellationEndTheQuestion() async {
        let prompts = UserPrompts()
        async let first = prompts.ask(UserPrompt(question: "A?", options: [], allowsText: true, source: .model))
        _ = await nextPrompt(prompts)
        prompts.cancelAll()
        #expect(await first == .cancelled)

        let task = Task { await prompts.ask(UserPrompt(question: "B?", options: [], allowsText: true, source: .model)) }
        _ = await nextPrompt(prompts)
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(prompts.pending == nil)
    }

    @Test func askUserToolReturnsTheReply() async throws {
        let tools = tools(SimulatedPhone())
        let prompts = tools.policy.prompts
        async let result = tools.ask(.init(question: "Which one?", options: ["Red", " Blue ", "Red"], allow_text: true))
        let pending = await nextPrompt(prompts)
        #expect(pending?.options == ["Red", "Blue"])
        #expect(pending?.allowsText == true)
        #expect(pending?.source == .model)
        prompts.answer(id: pending!.id, "The green one")
        let output = try await result
        #expect(output.joinedText == "The user replied: The green one")
        #expect(output.details?["reply"] == .string("The green one"))
    }

    @Test func askUserFailsWhenStopped() async throws {
        let tools = tools(SimulatedPhone())
        let result = Task { try await tools.ask(.init(question: "Send?", options: ["Send"], allow_text: nil)) }
        _ = await nextPrompt(tools.policy.prompts)
        tools.policy.requestStop()
        await #expect(throws: DriverError.self) { try await result.value }
        await #expect(throws: DriverError.self) { try await tools.ask(.init(question: "Again?")) }
    }

    @Test func policyAsksBeforeListedToolsAndApps() async {
        let policy = SafetyPolicy(
            configuration: .init(maxStepsPerRun: 10, confirmTools: ["open_url"], confirmApps: ["com.bank.app"]),
            screen: ScreenState())
        let app = AppInfo(bundleID: "com.example", name: "Example")
        #expect(!policy.needsApproval(tool: "tap", app: app))
        #expect(policy.needsApproval(tool: "open_url", app: app))
        #expect(policy.needsApproval(tool: "tap", app: AppInfo(bundleID: "com.bank.app")))
        #expect(!policy.needsApproval(tool: "press_home", app: AppInfo(bundleID: "com.bank.app")))
        #expect(!policy.needsApproval(tool: "view_screen", app: AppInfo(bundleID: "com.bank.app")))

        async let allowed = policy.approve(tool: "open_url", action: "open https://example.com", app: app)
        let first = await nextPrompt(policy.prompts)
        #expect(first?.question == "Allow the agent to open https://example.com in Example?")
        #expect(first?.source == .policy)
        policy.prompts.answer(id: first!.id, UserPrompt.approve)
        #expect(await allowed == .allow)

        async let denied = policy.approve(tool: "open_url", action: "open https://example.com", app: app)
        let second = await nextPrompt(policy.prompts)
        policy.prompts.answer(id: second!.id, UserPrompt.deny)
        #expect(await denied != .allow)
    }

    @Test func batchesWaitForApproval() async throws {
        let phone = SimulatedPhone()
        let tools = tools(phone, policy: .init(confirmTools: ["press_home"]))
        async let batch = tools.batch([try args(#"{"action":"press_home"}"#)])
        let pending = await nextPrompt(tools.policy.prompts)
        #expect(pending?.question.hasPrefix("Allow the agent to go to the Home Screen") == true)
        tools.policy.prompts.answer(id: pending!.id, UserPrompt.deny)
        #expect(try await batch.joinedText.contains("was blocked: The user did not allow"))
        #expect(tools.policy.stepsTaken == 0)
    }

    @Test func oldConfigurationsDecodeWithEmptyConfirmLists() throws {
        let configuration = try JSONDecoder().decode(
            SafetyPolicy.Configuration.self, from: Data(#"{"maxStepsPerRun":5,"blockedApps":[]}"#.utf8))
        #expect(configuration == .init(maxStepsPerRun: 5, blockedApps: []))
    }
}
