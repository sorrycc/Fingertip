import AgentCore
import SwiftUI

/// The run in progress, as the status bar and the Live Activity show it.
struct RunInfo: Equatable {
    /// The user's request.
    var request: String
    /// What the agent is doing: "Tapped “Search”", "Thinking…", "Waiting for you".
    var action: String
    /// The app the agent is in.
    var app: String?
    var steps: Int
    var maxSteps: Int
    var startedAt: Date
}

extension Transcript.Status {
    /// One line for the status bar.
    var summary: String {
        switch self {
        case .idle: "Done"
        case .thinking: "Thinking…"
        case .acting(let title): title
        case .waitingForUser: "Waiting for you"
        case .retrying: "Model error, retrying…"
        }
    }
}

extension Transcript {
    /// The latest request, for the status bar.
    var lastRequest: String? {
        for item in items.reversed() {
            if case .user(_, let text) = item { return text }
        }
        return nil
    }

    /// When the live activity started, so a resumed run keeps its clock.
    var liveActivityStart: Date? {
        for item in items.reversed() {
            if case .activity(let activity) = item, activity.isLive { return activity.startedAt }
        }
        return nil
    }

    /// Whether the last run ended with Stop.
    var endedStopped: Bool {
        if case .notice(_, .stopped) = items.last { return true }
        return false
    }
}

/// Pinned above the chat while the agent works: the request, what it is doing, where, how far, and Stop.
/// A question from the agent expands it into a card with its options.
struct AgentStatusBar: View {
    let run: RunInfo
    let prompt: UserPrompt?
    let onAnswer: (String) -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                StatusDot(color: prompt == nil ? .accentColor : .orange, pulsing: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.request)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(run.action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .shimmering(active: prompt == nil)
                }
                Spacer(minLength: 4)
                Button("Stop", systemImage: "stop.fill", action: onStop)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.red.gradient, in: .circle)
                    .buttonStyle(PressableStyle())
            }
            HStack(spacing: 6) {
                if let app = run.app { Chip(systemImage: "app.fill", text: app) }
                Chip(systemImage: "hand.tap", text: "\(run.steps)/\(run.maxSteps)")
                    .accessibilityLabel("\(run.steps) of \(run.maxSteps) actions")
                TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
                    Chip(systemImage: "clock", text: Self.elapsed(from: run.startedAt, to: context.date))
                }
                Spacer(minLength: 0)
            }
            if let prompt {
                PromptCard(prompt: prompt, onAnswer: onAnswer)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(12)
        .glassEffect(
            .regular.tint(prompt == nil ? nil : Color.orange.opacity(0.12)),
            in: .rect(cornerRadius: 22, style: .continuous))
        .animation(.snappy, value: prompt)
        .animation(.snappy, value: run.action)
        .accessibilityElement(children: .contain)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Chip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: .capsule)
    }
}

/// The agent's question with a button per option, and a reply field when it takes typed answers.
private struct PromptCard: View {
    let prompt: UserPrompt
    let onAnswer: (String) -> Void
    @State private var reply = ""
    @FocusState private var replying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(prompt.question).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: prompt.source == .policy ? "checkmark.shield.fill" : "questionmark.bubble.fill")
                    .foregroundStyle(.orange)
            }
            if !prompt.options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            onAnswer(option)
                        } label: {
                            Text(option)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .foregroundStyle(index == 0 ? Color.white : Color.primary)
                                .background(
                                    index == 0 ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                    in: .capsule)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            if prompt.allowsText {
                HStack(spacing: 8) {
                    TextField(prompt.options.isEmpty ? "Your answer" : "Or type an answer", text: $reply)
                        .focused($replying)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06), in: .capsule)
                    Button("Send", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.brand, in: .circle)
                        .buttonStyle(PressableStyle())
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.4 : 1)
                }
            }
        }
        .sensoryFeedback(.warning, trigger: prompt.id)
    }

    private var trimmed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
        reply = ""
        replying = false
    }
}
