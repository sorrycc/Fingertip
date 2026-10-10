import AgentCore
import PiDurableKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var automation: AutomationSession
    @State private var draft = ""
    @State private var showSetup = false
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBanner(showSetup: $showSetup)
                transcript
                composer
            }
            .navigationTitle("iPhone Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSetup = true } label: { Image(systemName: "hand.tap") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New task", systemImage: "square.and.pencil") { Task { await model.newTask() } }
                        Button("Settings", systemImage: "gear") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSetup) { SetupView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { if !automation.pairingLoaded { showSetup = true } }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let view = model.view {
                        ForEach(view.entries) { entry in
                            EntryRow(entry: entry, view: view)
                        }
                        if let message = view.streamingMessage, !message.text.isEmpty {
                            Bubble(text: message.text, isUser: false).opacity(0.7)
                        }
                        ForEach(view.live.tools) { slot in
                            Label("\(slot.name) …", systemImage: "gearshape.2")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let retry = view.live.generation?.retry {
                            Text("Retrying: \(retry.error)").font(.caption).foregroundStyle(.orange)
                        }
                    } else if model.isOpening {
                        ProgressView("Opening agent…").frame(maxWidth: .infinity)
                    } else {
                        EmptyState()
                    }
                    if let error = model.agentError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.view?.entries.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the agent to do something…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            if model.isBusy {
                Button { Task { await model.stop() } } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32)).foregroundStyle(.red)
                }
            } else {
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    inputFocused = false
                    Task { await model.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Automation readiness, shown above the transcript until ready.
private struct StatusBanner: View {
    @EnvironmentObject private var automation: AutomationSession
    @Binding var showSetup: Bool

    var body: some View {
        switch automation.phase {
        case .ready:
            EmptyView()
        case .idle:
            banner("UI automation is off", systemImage: "hand.raised.slash", tint: .orange)
        case .starting(let step):
            banner(step, systemImage: "hourglass", tint: .blue)
        case .failed(let message):
            banner(message, systemImage: "exclamationmark.triangle", tint: .red)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Button { showSetup = true } label: {
            Label(text, systemImage: systemImage)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(tint.opacity(0.12))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try:").font(.headline)
            ForEach([
                "Open Maps and find the nearest coffee shop that's open now",
                "In Safari, search tomorrow's weather in London and tell me",
                "Create a note titled Groceries with milk, eggs and bread",
            ], id: \.self) { Text("• \($0)").font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.top, 40)
    }
}

private struct EntryRow: View {
    let entry: Entry
    let view: ConversationView

    var body: some View {
        switch entry.message {
        case .user(let message):
            Bubble(text: message.text, isUser: true)
        case .assistant(let message):
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty { Bubble(text: message.text, isUser: false) }
                ForEach(message.toolCalls) { call in ToolCallRow(call: call, result: result(for: call)) }
                if let error = message.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        case .system, .toolResult, .other, nil:
            EmptyView()
        }
    }

    private func result(for call: ToolCall) -> ToolResultMessage? {
        view.entries.lazy.compactMap(\.toolResult).first { $0.toolCallId == call.id }
    }
}

private struct ToolCallRow: View {
    let call: ToolCall
    let result: ToolResultMessage?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 18)
                    Text(summary).lineLimit(1)
                    Spacer()
                    if let result {
                        Image(systemName: result.isError ? "xmark.circle" : "checkmark.circle")
                            .foregroundStyle(result.isError ? .red : .green)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded, let result {
                Text(result.text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var summary: String {
        let args = call.arguments.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.stringValue.map { "\"\($0)\"" } ?? value.description)"
        }
        return "\(call.name)(\(args.joined(separator: ", ")))"
    }

    private var icon: String {
        switch call.name {
        case "view_screen": "eye"
        case "screenshot": "camera"
        case "tap", "long_press": "hand.tap"
        case "type_text": "keyboard"
        case "swipe": "hand.draw"
        case "press_home": "house"
        case "launch_app", "open_url": "arrow.up.forward.app"
        case "wait": "clock"
        default: "wrench"
        }
    }
}

private struct Bubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .padding(10)
                .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
