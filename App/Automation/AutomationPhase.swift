/// Where on-device UI automation is.
enum AutomationPhase: Equatable {
    case idle
    case starting(AutomationStartStep)
    case ready
    case failed(String)
}

/// The stages of `AutomationSession.start()`, in order.
enum AutomationStartStep: Int, CaseIterable, Equatable {
    case permission, tunnel, selfRunner

    var title: String {
        switch self {
        case .permission: "Checking Local Network access"
        case .tunnel: "Connecting through LocalDevVPN"
        case .selfRunner: "Starting XCTest — enter your passcode when asked"
        }
    }
}
