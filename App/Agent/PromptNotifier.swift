import AgentCore
import Foundation
import UserNotifications

/// Puts the agent's questions in a notification with a button per option (and a reply field), and hands the
/// answers back.
@MainActor
final class PromptNotifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let categoryPrefix = "prompt."
    nonisolated private static let optionPrefix = "option."
    nonisolated private static let replyAction = "reply"

    var onAnswer: ((_ promptID: String, _ reply: String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ prompt: UserPrompt) async {
        let center = UNUserNotificationCenter.current()
        var actions: [UNNotificationAction] = prompt.options.enumerated().map { index, option in
            UNNotificationAction(identifier: Self.optionPrefix + "\(index)", title: option, options: [])
        }
        if prompt.allowsText {
            actions.append(UNTextInputNotificationAction(
                identifier: Self.replyAction, title: "Reply…", options: [], textInputButtonTitle: "Send",
                textInputPlaceholder: "Your answer"))
        }
        let category = Self.categoryPrefix + prompt.id
        // Only the latest question can be answered, so its category replaces the others.
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])])

        let content = UNMutableNotificationContent()
        content.title = prompt.source == .policy ? "Approve this action?" : "Fingertip needs you"
        content.body = prompt.question
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .active
        content.userInfo = ["promptID": prompt.id, "options": prompt.options]
        try? await center.add(UNNotificationRequest(identifier: prompt.id, content: content, trigger: nil))
    }

    /// Removes the question's notification once it is answered or cancelled.
    func clear(_ promptID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [promptID])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [promptID])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let promptID = info["promptID"] as? String else { return }
        let options = info["options"] as? [String] ?? []
        let action = response.actionIdentifier
        var reply: String?
        if let text = response as? UNTextInputNotificationResponse {
            reply = text.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if action.hasPrefix(Self.optionPrefix), let index = Int(action.dropFirst(Self.optionPrefix.count)),
                  options.indices.contains(index) {
            reply = options[index]
        }
        guard let reply, !reply.isEmpty else { return }
        await MainActor.run { onAnswer?(promptID, reply) }
    }

    /// In the app, the chat shows questions itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
