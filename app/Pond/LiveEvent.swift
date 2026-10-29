import ActivityKit
import Foundation
import PondKit

/// Starts, changes and ends the Live Activity of today's live event (R15). The app calls it at each offer, pick and "Done":
/// the activity starts when the app opens on the event's day, and it ends 3 hours after the start or after "Done".
enum LiveEvent {
    static let length: TimeInterval = 3 * 3600

    @MainActor
    static func update(_ day: InviteDay?, events: [Event]) {
        guard let day, day.date == Menu.day(.now) else { return }
        let ids = day.choices.compactMap { if case .event(let id) = $0.source { id } else { nil } }
        let event = events.first { ids.contains($0.id) && $0.start + length > .now }
        let done = day.done && day.picked.map { if case .event = $0.source { true } else { false } } == true
        for activity in Activity<EventAttributes>.activities where activity.activityState == .active {
            if activity.attributes.id != event?.id || day.done {
                let content = ActivityContent(state: EventAttributes.ContentState(done: done), staleDate: nil)
                let id = activity.id
                Task.detached {
                    let activity = Activity<EventAttributes>.activities.first { $0.id == id }
                    await activity?.end(content, dismissalPolicy: done ? .after(.now + 15 * 60) : .immediate)
                }
            }
        }
        guard let event, !day.done, ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<EventAttributes>.activities.contains(where: { $0.attributes.id == event.id }) else { return }
        let attributes = EventAttributes(id: event.id, day: day.date, title: event.title, place: event.place, start: event.start,
                                         cost: event.cost, directions: event.directions)
        _ = try? Activity.request(attributes: attributes,
                                  content: ActivityContent(state: EventAttributes.ContentState(), staleDate: event.start + length))
    }
}
