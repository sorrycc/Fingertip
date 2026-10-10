import SwiftUI

@main
struct IPhoneAgentApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(model)
                .environmentObject(model.automation)
                .task { await model.openAgent() }
        }
    }
}
