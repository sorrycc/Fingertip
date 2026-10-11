import AgentCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AgentSettings.load()
    @State private var apiKeys = Self.storedKeys(AgentSettings.load())
    @State private var confirmReset = false
    @State private var originalKeys = Self.storedKeys(AgentSettings.load())

    private static func storedKeys(_ settings: AgentSettings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: settings.providers.map { ($0.id, APIKeyStore.key(for: $0.id) ?? "") })
    }

    private var trimmedKeys: [String: String] { apiKeys.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    private var hasChanges: Bool { draft != model.settings || trimmedKeys != originalKeys }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ModelPicker(providers: draft.providers, selection: $draft.selection) {
                        SettingLabel("Active model", systemImage: "cpu", tint: .indigo)
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Model")
                } footer: {
                    if let problem = draft.modelProblem {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    } else if trimmedKeys[draft.selection.providerID, default: ""].isEmpty {
                        Label("Add an API key for \(draft.selectedProvider?.displayName ?? "this provider").", systemImage: "key")
                            .foregroundStyle(.orange)
                    } else {
                        Text("You can also switch models from the chat.")
                    }
                }

                Section {
                    ForEach($draft.providers) { $provider in
                        NavigationLink {
                            ProviderEditor(provider: $provider, apiKey: binding(forKey: provider.id))
                        } label: {
                            ProviderRow(provider: provider, hasKey: !trimmedKeys[provider.id, default: ""].isEmpty)
                        }
                    }
                    .onDelete { offsets in
                        withAnimation {
                            draft.providers.remove(atOffsets: offsets)
                            draft.fixSelection()
                        }
                    }
                    Button("Add Provider", systemImage: "plus") {
                        withAnimation { draft.providers.append(.new()) }
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Any Anthropic Messages–compatible API. Keys are stored in the Keychain on this device only.")
                }

                Section {
                    Stepper(value: $draft.maxStepsPerRun, in: 5...300, step: 5) {
                        HStack {
                            SettingLabel("Actions per request", systemImage: "gauge.with.dots.needle.67percent", tint: .orange)
                            Spacer()
                            Text("\(draft.maxStepsPerRun)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        BlockedAppsView(apps: $draft.blockedAppList)
                    } label: {
                        HStack {
                            SettingLabel("Blocked apps", systemImage: "hand.raised.fill", tint: .red)
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
                    Toggle(isOn: $draft.returnToAppWhenDone) {
                        SettingLabel("Return here when done", systemImage: "arrow.uturn.backward", tint: .blue)
                    }
                } footer: {
                    Text("Brings you back to the chat with the answer when a task finishes in another app.")
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) { confirmReset = true }
                        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                            Button("Reset", role: .destructive) {
                                withAnimation { draft = AgentSettings() }
                                for preset in draft.providers where apiKeys[preset.id] == nil { apiKeys[preset.id] = "" }
                            }
                        } message: {
                            Text("Custom providers are removed. Keys for DeepSeek and ZenMux are kept.")
                        }
                }

                Section {
                } footer: {
                    AboutFooter()
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
                        let keys = trimmedKeys.filter { id, _ in settings.providers.contains { $0.id == id } }
                        Task { await model.save(settings, apiKeys: keys) }
                        dismiss()
                    }
                    .disabled(!hasChanges || draft.modelProblem != nil)
                }
            }
        }
        .onAppear {
            draft = model.settings
            originalKeys = Self.storedKeys(model.settings)
            apiKeys = originalKeys
        }
    }

    private func binding(forKey provider: String) -> Binding<String> {
        Binding(get: { apiKeys[provider, default: ""] }, set: { apiKeys[provider] = $0 })
    }
}

/// Picks a model, grouped by provider.
struct ModelPicker<Label: View>: View {
    let providers: [ProviderProfile]
    @Binding var selection: ModelSelection
    @ViewBuilder let label: Label

    var body: some View {
        Picker(selection: $selection) {
            ForEach(providers.filter { !$0.models.isEmpty }) { provider in
                Section(provider.displayName) {
                    ForEach(provider.models, id: \.self) { model in
                        Text(model).tag(ModelSelection(providerID: provider.id, modelID: model))
                    }
                }
            }
        } label: {
            label
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderProfile
    let hasKey: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "network", tint: .blue, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(provider.url?.host() ?? "No endpoint").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if provider.problem != nil || !hasKey {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(provider.problem != nil ? .red : .orange)
                    .accessibilityLabel(provider.problem ?? "No API key")
            } else {
                Text(provider.models.count == 1 ? "1 model" : "\(provider.models.count) models").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderEditor: View {
    @Binding var provider: ProviderProfile
    @Binding var apiKey: String
    @State private var revealKey = false
    @State private var newModel = ""

    var body: some View {
        Form {
            Section {
                LabeledField("Name", systemImage: "tag.fill", tint: .teal) {
                    TextField(provider.url?.host() ?? "My provider", text: $provider.name)
                }
                LabeledField("Endpoint", systemImage: "network", tint: .blue) {
                    TextField("https://…", text: $provider.baseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                }
                LabeledField("API key", systemImage: "key.fill", tint: .gray) {
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
                Toggle(isOn: $provider.supportsImages) {
                    SettingLabel("Screenshots", systemImage: "camera.viewfinder", tint: .purple,
                                 detail: "Lets the model look at screens the accessibility tree can't describe.")
                }
            } footer: {
                if let problem = provider.problem {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }

            Section {
                ForEach(provider.models, id: \.self) { model in
                    Text(model).font(.body.monospaced())
                }
                .onDelete { provider.models.remove(atOffsets: $0) }
                .onMove { provider.models.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("model-id", text: $newModel)
                        .onSubmit(addModel)
                        .submitLabel(.done)
                    Button("Add", action: addModel)
                        .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Model ids as the provider names them, for example anthropic/claude-sonnet-5.5.")
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func addModel() {
        let model = newModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        if !provider.models.contains(model) { withAnimation { provider.models.append(model) } }
        newModel = ""
    }
}

/// A Settings-style row title with a tinted icon tile and an optional explanation.
private struct SettingLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    var detail: String?

    init(_ title: String, systemImage: String, tint: Color, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AboutFooter: View {
    var body: some View {
        VStack(spacing: 6) {
            AgentGlyph(size: 36)
            Text(Bundle.main.displayName).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
            Text("Version \(Bundle.main.versionString)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// A form row with a fixed-width leading label, so fields line up.
private struct LabeledField<Field: View>: View {
    let label: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let field: Field

    init(_ label: String, systemImage: String, tint: Color, @ViewBuilder field: () -> Field) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, tint: tint, size: 28)
            Text(label).frame(width: 72, alignment: .leading)
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
    var displayName: String {
        object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Agent"
    }

    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
