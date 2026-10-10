import AgentCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AgentSettings.load()
    @State private var apiKey = APIKeyStore.key ?? ""
    @State private var revealKey = false
    @State private var confirmReset = false
    private let originalKey = APIKeyStore.key ?? ""

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { draft != model.settings || trimmedKey != originalKey }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField("Endpoint") {
                        TextField("https://…", text: $draft.baseURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                    }
                    LabeledField("Model") {
                        TextField("model-id", text: $draft.modelID)
                    }
                    LabeledField("API key") {
                        HStack {
                            Group {
                                if revealKey {
                                    TextField("Required", text: $apiKey)
                                } else {
                                    SecureField("Required", text: $apiKey)
                                }
                            }
                            .font(revealKey && !apiKey.isEmpty ? .body.monospaced() : .body)
                            Button(revealKey ? "Hide key" : "Show key", systemImage: revealKey ? "eye.slash" : "eye") {
                                revealKey.toggle()
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                        }
                    }
                    Toggle(isOn: $draft.supportsImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screenshots")
                            Text("Lets the model look at screens the accessibility tree can't describe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if let problem = draft.modelProblem {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    } else if model.needsRelaunch {
                        Label("Relaunch the app to use the new model settings.", systemImage: "arrow.clockwise")
                    } else {
                        Text("Any Anthropic Messages–compatible API. The key is stored in the Keychain on this device only.")
                    }
                }

                Section {
                    Stepper(value: $draft.maxStepsPerRun, in: 5...300, step: 5) {
                        HStack {
                            Text("Actions per request")
                            Spacer()
                            Text("\(draft.maxStepsPerRun)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        BlockedAppsView(apps: $draft.blockedAppList)
                    } label: {
                        HStack {
                            Text("Blocked apps")
                            Spacer()
                            Text("\(draft.blockedAppList.count)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("The agent stops after this many taps, swipes, or keystrokes, and never acts inside blocked apps. It won't buy, send, or post unless you ask it to.")
                }

                Section {
                    Toggle("Return here when done", isOn: $draft.returnToAppWhenDone)
                } footer: {
                    Text("Brings you back to the chat with the answer when a task finishes in another app.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                withAnimation { draft = AgentSettings() }
                            }
                        } message: {
                            Text("Your API key is kept.")
                        }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionString)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        let settings = draft
                        let key = trimmedKey
                        Task { await model.save(settings, apiKey: key) }
                        dismiss()
                    }
                    .disabled(!hasChanges || draft.modelProblem != nil)
                }
            }
        }
        .onAppear { draft = model.settings }
    }
}

/// A form row with a fixed-width leading label, so fields line up.
private struct LabeledField<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 78, alignment: .leading)
            field
        }
    }
}

private struct BlockedAppsView: View {
    @Binding var apps: [String]
    @State private var newApp = ""
    @FocusState private var adding: Bool

    var body: some View {
        List {
            Section {
                ForEach(apps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 1) {
                        if let name = Transcript.appName(forBundleID: app) {
                            Text(name)
                            Text(app).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } else {
                            Text(app)
                        }
                    }
                }
                .onDelete { apps.remove(atOffsets: $0) }
                HStack {
                    TextField("Bundle id or app name", text: $newApp)
                        .focused($adding)
                        .onSubmit(add)
                        .submitLabel(.done)
                    Button("Add", action: add)
                        .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("For example com.apple.Passbook or “Banking”. The agent can't tap, type, or swipe while one of these is open, and can't launch them.")
            }
            Section {
                Button("Restore Defaults") {
                    withAnimation { apps = SafetyPolicy.Configuration.defaultBlockedApps }
                }
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Blocked Apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func add() {
        let app = newApp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !app.isEmpty else { return }
        if !apps.contains(app) { withAnimation { apps.append(app) } }
        newApp = ""
    }
}

extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
