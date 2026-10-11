import ActivityKit
import AgentCore
import Foundation

/// Keeps the run's Live Activity (Lock Screen and Dynamic Island) in step with the agent.
@MainActor
final class LiveActivityController {
    private var activity: ActivityKit.Activity<AgentActivityAttributes>?
    private var last: AgentActivityAttributes.ContentState?

    init() {
        // A run iOS interrupted resumes in the same activity; anything else is left over.
        activity = ActivityKit.Activity<AgentActivityAttributes>.activities.first
    }

    /// Shows the run, starting the activity if needed. A new question alerts like a notification.
    func show(_ run: RunInfo, prompt: UserPrompt?) async {
        let state = AgentActivityAttributes.ContentState(
            phase: prompt == nil ? .working : .waiting, action: run.action, app: run.app, steps: run.steps,
            maxSteps: run.maxSteps, prompt: prompt.map(Self.prompt))
        guard state != last else { return }
        let isNewQuestion = prompt != nil && prompt?.id != last?.prompt?.id
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity, activity.activityState == .active, activity.attributes.request == run.request {
            let alert = isNewQuestion
                ? AlertConfiguration(title: "Fingertip needs you", body: "\(prompt?.question ?? "")", sound: .default) : nil
            await activity.update(content, alertConfiguration: alert)
            return
        }
        await endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try ActivityKit.Activity.request(
                attributes: AgentActivityAttributes(request: run.request, startedAt: run.startedAt), content: content)
        } catch {
            print("[live-activity] \(error.localizedDescription)")
        }
    }

    /// Ends the activity with how the run ended; it stays on the Lock Screen a few minutes.
    func finish(_ run: RunInfo, answer: String?, stopped: Bool) async {
        guard let activity else { return }
        let state = AgentActivityAttributes.ContentState(
            phase: stopped ? .stopped : .finished,
            action: stopped ? "Stopped" : answer.map { String($0.prefix(160)) } ?? "Done",
            app: run.app, steps: run.steps, maxSteps: run.maxSteps, prompt: nil)
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 5 * 60))
        self.activity = nil
        last = nil
    }

    /// Ends leftover activities still showing a run in progress; finished ones keep their dismissal time.
    func endAll() async {
        for activity in ActivityKit.Activity<AgentActivityAttributes>.activities where activity.activityState == .active {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        last = nil
    }

    private static func prompt(_ prompt: UserPrompt) -> AgentActivityAttributes.ContentState.Prompt {
        .init(id: prompt.id, question: prompt.question, options: prompt.options, allowsText: prompt.allowsText)
    }
}
