import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = APIKeyStore.key ?? ""
    @State private var original = AgentSettings.load()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Base URL", text: $model.settings.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Model", text: $model.settings.modelID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                    Toggle("Model accepts images", isOn: $model.settings.supportsImages)
                } header: {
                    Text("Model (Anthropic-compatible API)")
                } footer: {
                    Text("Model, URL, and key changes apply the next time the app launches.")
                }

                Section {
                    Stepper("Max actions per request: \(model.settings.maxStepsPerRun)",
                            value: $model.settings.maxStepsPerRun, in: 5...300, step: 5)
                    VStack(alignment: .leading) {
                        Text("Blocked apps (bundle ids or names, comma separated)").font(.caption)
                        TextField("com.apple.Passbook, …", text: $model.settings.blockedApps, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("Return to this app when done", isOn: $model.settings.returnToAppWhenDone)
                } header: {
                    Text("Safety")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.settings = original
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        APIKeyStore.key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.applySettings()
                        dismiss()
                    }
                }
            }
        }
    }
}
