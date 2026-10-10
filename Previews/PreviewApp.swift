import AgentCore
import SwiftUI

/// Simulator-only build of the UI with scripted data, for design work without a phone.
/// Pick a state with the `-scenario` launch argument: empty, setup, starting, working, done, failed;
/// or open a screen directly: settings, log.
@main
struct PreviewApp: App {
    @State private var model = AppModel(scenario: UserDefaults.standard.string(forKey: "scenario") ?? "done")

    var body: some Scene {
        WindowGroup {
            Group {
                switch UserDefaults.standard.string(forKey: "scenario") {
                case "settings": SettingsView()
                case "log": NavigationStack { LogView(logger: model.automation.logger) }
                default: ChatView()
                }
            }
                .environment(model)
                .environment(model.automation)
        }
    }
}
