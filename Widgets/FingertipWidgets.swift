import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct FingertipWidgets: WidgetBundle {
    var body: some Widget {
        AgentLiveActivity()
    }
}

/// The agent's run: what it is doing, where, how far along, and its question when it waits for the user.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.app ?? "Fingertip", systemImage: "hand.tap.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.tint)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StepsAndTime(state: state, startedAt: context.attributes.startedAt)
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let prompt = state.prompt {
                            PromptView(prompt: prompt)
                        } else {
                            Text(context.attributes.request).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                Text(state.action).font(.subheadline.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 8)
                                if state.isActive { StopButton() }
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.phase == .waiting ? "questionmark.bubble.fill" : "hand.tap.fill")
                    .foregroundStyle(state.phase == .waiting ? Color.orange : Brand.tint)
            } compactTrailing: {
                if state.phase == .waiting {
                    Text("Ask").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("\(state.steps)").font(.caption2.monospacedDigit()).foregroundStyle(Brand.tint)
                }
            } minimal: {
                Image(systemName: state.phase == .waiting ? "questionmark.bubble.fill" : "hand.tap.fill")
                    .foregroundStyle(state.phase == .waiting ? Color.orange : Brand.tint)
            }
            .keylineTint(Brand.tint)
        }
    }
}

private enum Brand {
    static let tint = Color(red: 0.55, green: 0.5, blue: 1.0)
}

private struct LockScreenView: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").foregroundStyle(Brand.tint)
                Text(attributes.request).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                StepsAndTime(state: state, startedAt: attributes.startedAt).font(.caption)
            }
            if let prompt = state.prompt {
                PromptView(prompt: prompt)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.action).font(.subheadline).lineLimit(2)
                        if let app = state.app { Text("in \(app)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    if state.isActive { StopButton() }
                }
            }
        }
        .foregroundStyle(.white)
    }
}

private struct StepsAndTime: View {
    let state: AgentActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        HStack(spacing: 6) {
            Text("\(state.steps)/\(state.maxSteps)").monospacedDigit()
            if state.isActive {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 48)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// The question, with a button per option. Typed answers need the app or the notification.
private struct PromptView: View {
    let prompt: AgentActivityAttributes.ContentState.Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(prompt.question, systemImage: "questionmark.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white, .orange)
                .lineLimit(3)
            if prompt.options.isEmpty {
                Text("Open Fingertip to answer").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        Button(intent: AnswerPromptIntent(promptID: prompt.id, reply: option)) {
                            Text(option).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(index == 0 ? Brand.tint : Color.white.opacity(0.25))
                    }
                }
            }
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopAgentIntent()) {
            Image(systemName: "stop.fill").font(.caption.weight(.bold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(.red)
        .accessibilityLabel("Stop")
    }
}

extension AgentActivityAttributes.ContentState {
    var isActive: Bool { phase == .working || phase == .waiting }
}
