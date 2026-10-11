import AgentCore
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AutomationSession.self) private var automation
    @State private var draft = ""
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var sent = 0
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .background(Color(.systemBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .sheet(isPresented: $showSetup) { SetupView() }
                .sheet(isPresented: $showSettings) { SettingsView() }
                .onAppear { if !automation.pairingLoaded { showSetup = true } }
                .sensoryFeedback(.impact(weight: .light), trigger: sent)
                .sensoryFeedback(trigger: model.isBusy) { wasBusy, isBusy in wasBusy && !isBusy ? .success : nil }
        }
    }

    @ViewBuilder private var content: some View {
        if model.transcript.isEmpty {
            EmptyChatView(showSetup: $showSetup, showSettings: $showSettings) { prompt in
                draft = prompt
                inputFocused = true
            }
        } else {
            TranscriptList(transcript: model.transcript)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        ToolbarItem(placement: .principal) {
            Button { showSetup = true } label: {
                VStack(spacing: 1) {
                    Text("Fingertip").font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(color: model.isBusy ? .accentColor : automation.phase.tint, pulsing: automation.phase.isStarting || model.isBusy)
                        Text(model.isBusy ? "Working" : automation.phase.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Automation: \(automation.phase.title)")
            .accessibilityHint("Opens setup")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ModelPicker(providers: model.settings.providers, selection: Binding(
                    get: { model.settings.selection },
                    set: { selection in Task { await model.select(selection) } })) {
                    Text("Model")
                }
                .pickerStyle(.inline)
            } label: {
                Label("Model: \(model.settings.selection.modelID)", systemImage: "cpu")
            }
            .disabled(model.isBusy)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New task", systemImage: "square.and.pencil") {
                Task { await model.newTask() }
            }
            .disabled(model.transcript.isEmpty || model.isBusy)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let error = model.agentError {
                ErrorBar(message: error) { model.dismissError() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !automation.isReady, !model.transcript.isEmpty {
                AutomationBar(phase: automation.phase) { showSetup = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Composer(
                draft: $draft, focused: $inputFocused, isBusy: model.isBusy, isReady: automation.isReady,
                onSend: send, onStop: { Task { await model.stop() } })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: model.agentError)
        .animation(.snappy, value: automation.isReady)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard automation.isReady else {
            showSetup = true
            return
        }
        draft = ""
        sent += 1
        Task { await model.send(text) }
    }
}

// MARK: Transcript

private struct TranscriptList: View {
    let transcript: Transcript

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(transcript.items) { item in
                    TranscriptItemView(item: item).equatable()
                }
                RunStatusRow(status: transcript.status)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .animation(.snappy(duration: 0.3), value: transcript.status)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }
}

// MARK: Empty state

private struct EmptyChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(AutomationSession.self) private var automation
    @Binding var showSetup: Bool
    @Binding var showSettings: Bool
    let onPick: (String) -> Void

    private static let suggestions: [(icon: String, tint: Color, text: String)] = [
        ("map.fill", .green, "Open Maps and find the nearest coffee shop that's open now"),
        ("safari.fill", .blue, "In Safari, look up tomorrow's weather in London and tell me"),
        ("note.text", .yellow, "Create a note titled Groceries with milk, eggs and bread"),
        ("checklist", .orange, "Remind me to call Mom tomorrow at 6 pm"),
    ]

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    AgentGlyph(size: 64)
                        .shadow(color: Theme.brandEnd.opacity(0.35), radius: 18, y: 8)
                        .background { AmbientGlow().frame(width: 260, height: 260) }
                    Text("What should I do?")
                        .font(.title2.weight(.bold))
                    Text("Describe a task. I'll open the apps and tap through them for you, then come back with the result.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.top, 36)

                if let callout {
                    callout
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try asking")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.leading, 4)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Self.suggestions, id: \.text) { suggestion in
                            SuggestionCard(icon: suggestion.icon, tint: suggestion.tint, text: suggestion.text) {
                                onPick(suggestion.text)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The one thing standing between the user and a first run, if anything.
    private var callout: SetupCallout? {
        if model.isOpening { return nil }
        if !model.hasAPIKey {
            return SetupCallout(
                icon: "key.fill", tint: .orange, title: "Add your model API key",
                message: "The agent needs an Anthropic-compatible API key.", action: "Open Settings") { showSettings = true }
        }
        switch automation.phase {
        case .ready:
            return nil
        case .starting(let step):
            return SetupCallout(
                icon: "hourglass", tint: .orange, title: "Starting automation…", message: step.title,
                action: "View", progress: true) { showSetup = true }
        case .failed(let message):
            return SetupCallout(
                icon: "exclamationmark.triangle.fill", tint: .red, title: "Automation stopped", message: message,
                action: "Open Setup") { showSetup = true }
        case .idle:
            return SetupCallout(
                icon: "hand.tap.fill", tint: .accentColor, title: "Turn on UI automation",
                message: automation.pairingLoaded
                    ? "Takes about a minute. Then the agent can tap and type in any app."
                    : "Import your pairing files to get started.",
                action: automation.pairingLoaded ? "Start" : "Set up") { showSetup = true }
        }
    }
}

private struct SuggestionCard: View {
    let icon: String
    let tint: Color
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                IconTile(systemImage: icon, tint: tint, size: 30)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.cardFill, in: Theme.card)
            .overlay { Theme.card.strokeBorder(Theme.hairline) }
            .contentShape(Theme.card)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Puts this task in the message field")
    }
}

private struct SetupCallout: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    let action: String
    var progress = false
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                if progress {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    IconTile(systemImage: icon, tint: tint, size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Text(action)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(tint)
            }
            .padding(14)
            .background(Theme.cardFill, in: Theme.card)
            .overlay { Theme.card.strokeBorder(tint.opacity(0.25)) }
        }
        .buttonStyle(PressableStyle())
    }
}

/// Scales down slightly while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: Bottom bar

private struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let isBusy: Bool
    let isReady: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsStop: Bool { isBusy && !hasText }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.leading, 16)
                .padding(.vertical, 11)
            Button(action: showsStop ? onStop : onSend) {
                Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                    .font(.system(size: showsStop ? 14 : 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(buttonFill, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .disabled(!showsStop && !hasText)
            .padding(4)
            .accessibilityLabel(showsStop ? "Stop" : "Send")
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22, style: .continuous))
        .animation(.snappy(duration: 0.2), value: showsStop)
        .animation(.snappy(duration: 0.2), value: hasText)
    }

    private var placeholder: String {
        if isBusy { return "Add a follow-up…" }
        return isReady ? "Ask the agent to do something…" : "Describe a task…"
    }

    private var buttonFill: AnyShapeStyle {
        if showsStop { return AnyShapeStyle(Color.red.gradient) }
        return hasText ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.gray.opacity(0.35))
    }
}

/// Automation isn't running: a compact glass bar above the composer that opens Setup.
private struct AutomationBar: View {
    let phase: AutomationSession.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if phase.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: phase.systemImage).foregroundStyle(phase.tint)
                }
                Text(message).font(.footnote.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(phase.isStarting ? "View" : "Set up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var message: String {
        switch phase {
        case .starting(let step): step.title
        case .failed(let message): message
        default: "UI automation is off"
        }
    }
}

private struct ErrorBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.red.opacity(0.15)), in: .rect(cornerRadius: 16, style: .continuous))
    }
}
