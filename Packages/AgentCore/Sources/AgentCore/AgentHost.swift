import Foundation
import PiDurableKit

/// An Anthropic-compatible endpoint and the models the agent may pick from it.
public struct ModelProvider: Sendable, Hashable {
    /// Our own ids, so they don't collide with pi-ai's built-in providers (its `deepseek` is OpenAI-style).
    public var id: String
    public var name: String
    public var baseURL: URL
    public var apiKey: String
    public var modelIDs: [String]
    public var supportsImages: Bool
    public var contextWindow: Int
    public var maxTokens: Int

    public init(
        id: String,
        name: String,
        baseURL: URL,
        apiKey: String,
        modelIDs: [String],
        supportsImages: Bool = true,
        contextWindow: Int = 128_000,
        maxTokens: Int = 8_192
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelIDs = modelIDs
        self.supportsImages = supportsImages
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }

    /// DeepSeek's Anthropic-compatible endpoint.
    public static func deepSeek(apiKey: String) -> ModelProvider {
        ModelProvider(
            id: "fingertip-deepseek", name: "DeepSeek", baseURL: URL(string: "https://api.deepseek.com/anthropic")!,
            apiKey: apiKey, modelIDs: ["deepseek-flash"])
    }

    public func ref(_ modelID: String) -> ModelRef { ModelRef(provider: ProviderID(id), modelId: modelID) }

    var custom: CustomProvider {
        CustomProvider(
            id: ProviderID(id),
            name: name,
            baseURL: baseURL,
            api: .anthropicMessages,
            apiKey: apiKey,
            models: modelIDs.map {
                .init(
                    id: $0, name: $0, reasoning: false, input: supportsImages ? ["text", "image"] : ["text"],
                    contextWindow: contextWindow, maxTokens: maxTokens
                )
            }
        )
    }
}

/// A durable agent that drives a device: one harness, the root conversation, and the safety policy.
public final class AgentHost: Sendable {
    public let harness: Harness
    public let conversation: Conversation
    public let policy: SafetyPolicy
    public let screen: ScreenState
    let models: Models

    /// Questions the agent is waiting on the user to answer.
    public var prompts: UserPrompts { policy.prompts }

    init(harness: Harness, conversation: Conversation, policy: SafetyPolicy, screen: ScreenState, models: Models) {
        self.harness = harness
        self.models = models
        self.conversation = conversation
        self.policy = policy
        self.screen = screen
    }

    /// Opens (or reopens and resumes) the agent stored in `storage`, with every provider registered and `model` of
    /// `provider` selected.
    public static func open(
        providers: [ModelProvider],
        model: String,
        of provider: ModelProvider,
        storage: Storage,
        driver: any DeviceDriver,
        safety: SafetyPolicy.Configuration = .init(),
        options: ComputerUseOptions = .init(),
        credentials: any CredentialStore = InMemoryCredentialStore(),
        onReport: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentHost {
        let models = Models(credentials: credentials)
        for provider in Set(providers + [provider]) { try await models.register(provider.custom) }

        let screen = ScreenState()
        let policy = SafetyPolicy(configuration: safety, screen: screen)
        let computerUse = ComputerUse.makeExtension(driver: driver, state: screen, policy: policy, options: options)

        var settings = Settings()
        settings.extensions = [ComputerUse.extensionName]
        // Device actions must happen in order.
        settings.toolExecution = .sequential
        let harness = try await Harness.open(
            storage, models: models, extensions: [computerUse], settings: settings, onReport: onReport)

        let agent = await selection(model, of: provider, screen: screen)
        let conversation = try await harness.root(agent: agent)
        // The root keeps its first agent; apply config changes made since.
        try await conversation.configure(agent)
        return AgentHost(harness: harness, conversation: conversation, policy: policy, screen: screen, models: models)
    }

    /// Adds a provider, or replaces the one with the same id (new endpoint, key, or models).
    public func register(_ provider: ModelProvider) async throws {
        try await models.register(provider.custom)
    }

    /// Switches to `model` of `provider` (registered); it applies from the next model request.
    public func select(_ model: String, of provider: ModelProvider) async throws {
        try await conversation.configure(Self.selection(model, of: provider, screen: screen))
    }

    /// The agent change for a model; models without image input don't get the screenshot tool.
    private static func selection(_ model: String, of provider: ModelProvider, screen: ScreenState) async -> AgentChange {
        await screen.setImagesAllowed(provider.supportsImages)
        return provider.supportsImages
            ? AgentChange(model: provider.ref(model), thinkingLevel: .off, reset: [.tools])
            : AgentChange(model: provider.ref(model), thinkingLevel: .off, tools: .remove([ComputerUse.screenshotTool]))
    }

    /// Sends a user request, resetting the step budget and stop switch.
    @discardableResult
    public func send(_ text: String) async throws -> Submission {
        policy.beginRun()
        return try await conversation.submit(text, whenBusy: .steer)
    }

    /// Answers the question the agent is waiting on; returns false when it is no longer pending.
    @discardableResult
    public func answer(_ promptID: String, _ reply: String) -> Bool {
        prompts.answer(id: promptID, reply)
    }

    /// Stops the current run: blocks further actions, cancels a pending question, and aborts the model turn.
    public func stop() async {
        policy.requestStop()
        try? await conversation.abort()
    }

    /// Starts a fresh context, keeping the transcript.
    public func newTask() async throws {
        try await conversation.reset()
    }
}
