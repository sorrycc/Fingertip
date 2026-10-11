import SwiftUI

@main
struct FingertipApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environment(model)
                .environment(model.automation)
                .task { await model.openAgent() }
        }
    }
}
