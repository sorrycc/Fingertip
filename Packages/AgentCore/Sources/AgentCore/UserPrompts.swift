import Foundation
import os

/// A question the agent is waiting on the user to answer.
public struct UserPrompt: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// The model asked with `ask_user`.
        case model
        /// The safety policy asks before an action the user listed under "Ask before".
        case policy
    }

    public var id: String
    public var question: String
    /// Buttons to offer, in order. Empty means free text only.
    public var options: [String]
    /// Whether a typed reply is accepted besides the options.
    public var allowsText: Bool
    public var source: Source
    public var askedAt: Date

    public init(
        id: String = UUID().uuidString, question: String, options: [String], allowsText: Bool, source: Source,
        askedAt: Date = .now
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.allowsText = allowsText
        self.source = source
        self.askedAt = askedAt
    }

    /// The options of a policy prompt.
    public static let approve = "Allow"
    public static let deny = "Don't Allow"
}

/// How a prompt ended.
public enum UserReply: Sendable, Hashable {
    /// The user picked an option or typed a reply.
    case answered(String)
    /// The user pressed Stop, or the run ended.
    case cancelled
}

/// Holds the one question the agent is waiting on, and hands the user's reply back to it. There is no timeout:
/// the agent waits until the user answers or stops the run.
public final class UserPrompts: Sendable {
    private struct State {
        var pending: (prompt: UserPrompt, resume: CheckedContinuation<UserReply, Never>)?
        var observers: [UUID: AsyncStream<UserPrompt?>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The question waiting for an answer, if any.
    public var pending: UserPrompt? { state.withLock { $0.pending?.prompt } }

    /// The pending question now and on every change; `nil` when none is pending.
    public func updates() -> AsyncStream<UserPrompt?> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<UserPrompt?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        state.withLock {
            $0.observers[id] = continuation
            continuation.yield($0.pending?.prompt)
        }
        return stream
    }

    /// Asks and waits for the reply. A question asked while another is pending cancels the older one. Task
    /// cancellation cancels the question.
    public func ask(_ prompt: UserPrompt) async -> UserReply {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let replaced = state.withLock { state in
                    let old = state.pending
                    state.pending = (prompt, continuation)
                    state.observers.values.forEach { $0.yield(prompt) }
                    return old
                }
                replaced?.resume.resume(returning: .cancelled)
                if Task.isCancelled { cancel(id: prompt.id) }
            }
        } onCancel: {
            cancel(id: prompt.id)
        }
    }

    /// Answers the pending question; ignored when `id` is no longer pending. Returns whether it was answered.
    @discardableResult
    public func answer(id: String, _ reply: String) -> Bool {
        resolve(id: id, with: .answered(reply))
    }

    /// Cancels the pending question, if any (Stop).
    public func cancelAll() {
        let pending = state.withLock { state in
            let pending = state.pending
            state.pending = nil
            if pending != nil { state.observers.values.forEach { $0.yield(nil) } }
            return pending
        }
        pending?.resume.resume(returning: .cancelled)
    }

    private func cancel(id: String) {
        resolve(id: id, with: .cancelled)
    }

    @discardableResult
    private func resolve(id: String, with reply: UserReply) -> Bool {
        let pending = state.withLock { state -> CheckedContinuation<UserReply, Never>? in
            guard let pending = state.pending, pending.prompt.id == id else { return nil }
            state.pending = nil
            state.observers.values.forEach { $0.yield(nil) }
            return pending.resume
        }
        pending?.resume(returning: reply)
        return pending != nil
    }
}
