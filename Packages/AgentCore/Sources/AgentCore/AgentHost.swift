import Foundation
import PiDurableKit

/// Which model the agent calls. Defaults to DeepSeek's Anthropic-compatible endpoint.
public struct AgentConfig: Sendable, Hashable, Codable {
    public var baseURL: URL
    public var modelID: String
    public var supportsImages: Bool
    public var contextWindow: Int
    public var maxTokens: Int

    public init(
        baseURL: URL = URL(string: "https://api.deepseek.com/anthropic")!,
        modelID: String = "deepseek-flash",
        supportsImages: Bool = true,
        contextWindow: Int = 128_000,
        maxTokens: Int = 8_192
    ) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }

    /// Our own provider id, so it does not collide with pi-ai's built-in OpenAI-style `deepseek`.
    public static let providerID: ProviderID = "agent-anthropic"

    public var modelRef: ModelRef { ModelRef(provider: Self.providerID, modelId: modelID) }

    func provider(apiKey: String) -> CustomProvider {
        CustomProvider(
            id: Self.providerID,
            name: "Anthropic-compatible (\(baseURL.host() ?? "custom"))",
            baseURL: baseURL,
            api: .anthropicMessages,
            apiKey: apiKey,
            models: [
                .init(
                    id: modelID, name: modelID, reasoning: false, input: supportsImages ? ["text", "image"] : ["text"],
                    contextWindow: contextWindow, maxTokens: maxTokens
                ),
            ]
        )
    }
}

/// A durable agent that drives a device: one harness, the root conversation, and the safety policy.
public final class AgentHost: Sendable {
    public let harness: Harness
    public let conversation: Conversation
    public let policy: SafetyPolicy
    public let screen: ScreenState

    init(harness: Harness, conversation: Conversation, policy: SafetyPolicy, screen: ScreenState) {
        self.harness = harness
        self.conversation = conversation
        self.policy = policy
        self.screen = screen
    }

    /// Opens (or reopens and resumes) the agent stored in `storage`.
    public static func open(
        config: AgentConfig,
        apiKey: String,
        storage: Storage,
        driver: any DeviceDriver,
        safety: SafetyPolicy.Configuration = .init(),
        options: ComputerUseOptions = .init(),
        credentials: any CredentialStore = InMemoryCredentialStore(),
        onReport: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentHost {
        let models = Models(credentials: credentials)
        try await models.register(config.provider(apiKey: apiKey))

        let screen = ScreenState()
        let policy = SafetyPolicy(configuration: safety, screen: screen)
        var options = options
        options.allowScreenshots = options.allowScreenshots && config.supportsImages
        let computerUse = ComputerUse.makeExtension(driver: driver, state: screen, policy: policy, options: options)

        var settings = Settings()
        settings.extensions = [ComputerUse.extensionName]
        // Device actions must happen in order.
        settings.toolExecution = .sequential
        let harness = try await Harness.open(
            storage, models: models, extensions: [computerUse], settings: settings, onReport: onReport)

        let agent = AgentChange(model: config.modelRef, thinkingLevel: .off)
        let conversation = try await harness.root(agent: agent)
        // The root keeps its first agent; apply config changes made since.
        try await conversation.configure(agent)
        return AgentHost(harness: harness, conversation: conversation, policy: policy, screen: screen)
    }

    /// Sends a user request, resetting the step budget and stop switch.
    @discardableResult
    public func send(_ text: String) async throws -> Submission {
        policy.beginRun()
        return try await conversation.submit(text, whenBusy: .steer)
    }

    /// Stops the current run: blocks further actions and aborts the model turn.
    public func stop() async {
        policy.requestStop()
        try? await conversation.abort()
    }

    /// Starts a fresh context, keeping the transcript.
    public func newTask() async throws {
        try await conversation.reset()
    }
}
