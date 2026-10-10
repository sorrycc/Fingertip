import AgentCore
import SwiftUI

/// One transcript item. Equatable so unchanged rows skip re-rendering when the transcript updates.
struct TranscriptItemView: View, Equatable {
    let item: Transcript.Item

    var body: some View {
        switch item {
        case .user(_, let text):
            UserBubble(text: text)
        case .answer(_, let text, let isStreaming):
            AnswerView(text: text, isStreaming: isStreaming)
        case .activity(let activity):
            ActivityCard(activity: activity)
        case .notice(_, let notice):
            NoticeView(notice: notice)
        }
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 56)
            Text(text)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.brand, in: .rect(cornerRadius: 20, style: .continuous))
                .textSelection(.enabled)
                .contextMenu { CopyButton(text: text) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

struct AnswerView: View {
    let text: String
    var isStreaming = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentGlyph(size: 26)
            Text(isStreaming ? AttributedString(text) : Markdown.attributed(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .textSelection(.enabled)
                .opacity(isStreaming ? 0.75 : 1)
                .contextMenu { CopyButton(text: text) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent: \(text)")
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
    }
}

// MARK: Activity

/// The agent's on-device work for one request: a collapsible timeline of steps.
struct ActivityCard: View {
    let activity: Activity
    /// `nil` follows the run: open while live, folded when done.
    @State private var userExpanded: Bool?

    private var expanded: Bool { userExpanded ?? activity.isLive }
    private var steps: [Step] { activity.steps }
    private var failures: Int { steps.count { $0.status == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().padding(.leading, 14)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(activity.entries.enumerated()), id: \.element.id) { index, entry in
                        let isLast = index == activity.entries.count - 1
                        switch entry {
                        case .note(_, let text):
                            NoteRow(text: text, isLast: isLast)
                        case .step(let step):
                            StepRow(step: step, isLast: isLast)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Theme.cardFill, in: Theme.card)
        .clipShape(Theme.card)
        .animation(.snappy(duration: 0.25), value: expanded)
    }

    private var header: some View {
        Button {
            userExpanded = !expanded
        } label: {
            HStack(spacing: 10) {
                Group {
                    if activity.isLive {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: failures > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(failures > 0 ? Color.orange : Color.green)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Hides the steps" : "Shows the steps")
    }

    private var title: String {
        if activity.isLive { return "Working…" }
        guard let end = activity.endedAt else { return "Worked" }
        let seconds = max(Int(end.timeIntervalSince(activity.startedAt).rounded()), 1)
        return seconds < 60 ? "Worked for \(seconds)s" : "Worked for \(seconds / 60)m \(seconds % 60)s"
    }

    private var subtitle: String {
        var parts = [steps.count == 1 ? "1 step" : "\(steps.count) steps"]
        if failures > 0 { parts.append(failures == 1 ? "1 failed" : "\(failures) failed") }
        if activity.isLive, let current = steps.last { parts.append(current.title) }
        return parts.joined(separator: " · ")
    }
}

/// The leading column of a timeline row: an icon with a connector line down to the next row.
private struct TimelineMarker<Icon: View>: View {
    let isLast: Bool
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(spacing: 0) {
            icon.frame(width: 26, height: 26)
            if !isLast {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 26)
    }
}

private struct NoteRow: View {
    let text: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimelineMarker(isLast: isLast) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(Markdown.attributed(text))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, isLast ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StepRow: View {
    let step: Step
    let isLast: Bool
    @State private var showOutput = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TimelineMarker(isLast: isLast) {
                Circle()
                    .fill(tint.opacity(0.14))
                    .overlay {
                        Image(systemName: StepStyle.symbol(for: step.tool))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if step.output != nil || step.imageBase64 != nil { showOutput.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.subheadline)
                                .foregroundStyle(step.status == .interrupted ? .secondary : .primary)
                                .lineLimit(2)
                            if let detail = step.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(step.status == .failed ? Color.red : Color.secondary)
                                    .lineLimit(showOutput ? nil : 1)
                            }
                        }
                        Spacer(minLength: 4)
                        trailing
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if showOutput {
                    StepOutput(step: step)
                        .transition(.opacity)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, isLast ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.2), value: showOutput)
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText)
    }

    @ViewBuilder private var trailing: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        case .interrupted:
            Text("Stopped").font(.caption2).foregroundStyle(.tertiary)
        case .done:
            if let duration = step.duration {
                Text(StepStyle.format(duration)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
    }

    private var tint: Color {
        switch step.status {
        case .failed: .red
        case .interrupted: .secondary
        default: StepStyle.tint(for: step.tool)
        }
    }

    private var statusText: String {
        switch step.status {
        case .running: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        case .interrupted: "Stopped"
        }
    }
}

/// A step's raw output and screenshot, shown on demand.
private struct StepOutput: View {
    let step: Step
    @State private var image: UIImage?
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary) }
            }
            if let output = step.output {
                VStack(alignment: .leading, spacing: 6) {
                    Text(output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(showAll ? nil : 10)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        if output.count > 600 || output.split(separator: "\n").count > 10 {
                            Button(showAll ? "Show less" : "Show all") { showAll.toggle() }
                        }
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = output }
                            .labelStyle(.iconOnly)
                    }
                    .font(.caption.weight(.medium))
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
        .task(id: step.id) {
            guard image == nil, let base64 = step.imageBase64 else { return }
            image = await Task.detached(priority: .userInitiated) {
                Data(base64Encoded: base64).flatMap(UIImage.init(data:))?.preparingForDisplay()
            }.value
        }
    }
}

enum StepStyle {
    static func symbol(for tool: String) -> String {
        switch tool {
        case "view_screen": "eye.fill"
        case "screenshot": "camera.viewfinder"
        case "tap": "hand.tap.fill"
        case "long_press": "hand.point.up.fill"
        case "type_text": "keyboard.fill"
        case "swipe": "hand.draw.fill"
        case "press_home": "house.fill"
        case "launch_app": "square.grid.2x2.fill"
        case "open_url": "link"
        case "wait": "hourglass"
        default: "wrench.and.screwdriver.fill"
        }
    }

    static func tint(for tool: String) -> Color {
        switch tool {
        case "view_screen", "screenshot", "wait": .secondary
        case "type_text": .teal
        case "launch_app", "open_url", "press_home": .indigo
        default: .accentColor
        }
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return seconds < 1 ? "\(Int(seconds * 1000))ms" : seconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }
}

// MARK: Notices and status

struct NoticeView: View {
    let notice: Transcript.Notice

    var body: some View {
        switch notice {
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: .capsule)
                .frame(maxWidth: .infinity)
        case .error(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).font(.subheadline).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.red.opacity(0.1), in: Theme.card)
        }
    }
}

/// "Thinking…" with a shimmer, or a retry countdown, under the transcript while the model works.
struct RunStatusRow: View {
    let status: Transcript.Status

    var body: some View {
        switch status {
        case .thinking:
            HStack(spacing: 10) {
                AgentGlyph(size: 26)
                Text("Thinking…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .shimmering()
                Spacer()
            }
            .transition(.opacity)
        case .retrying(let at, let error):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(Int(at.timeIntervalSince(context.date).rounded(.up)), 0)
                        Text(seconds > 0 ? "Model error — retrying in \(seconds)s" : "Retrying…")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    if !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1), in: Theme.card)
        case .idle, .acting:
            EmptyView()
        }
    }
}

private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}
