import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity of today's live event (#widget in the mock-up, "Open mic · 20:00" with "Done"): the time, the place,
/// "Go" for the directions in Maps and "Done" for the entry.
struct EventActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventAttributes.self) { context in
            EventLockScreen(event: context.attributes, done: context.state.done)
                .activityBackgroundTint(Color.card)
                .activitySystemActionForegroundColor(Color.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("🎟").font(.title2) }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.start, style: .time).font(.headline) }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.title).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.bottom) {
                    EventButtons(event: context.attributes, done: context.state.done).foregroundStyle(.white)
                }
            } compactLeading: {
                Text("🎟")
            } compactTrailing: {
                Text(context.attributes.start, style: .time).font(.caption)
            } minimal: {
                Text("🎟")
            }
        }
    }
}

private struct EventLockScreen: View {
    let event: EventAttributes
    let done: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🎟")
                Text("\(event.title) · ").font(.headline) + Text(event.start, style: .time).font(.headline)
            }
            .lineLimit(2)
            Text(([event.place] + [event.cost].compactMap { $0 }).joined(separator: " · "))
                .font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
            EventButtons(event: event, done: done)
        }
        .foregroundStyle(Color.ink)
        .padding(14)
    }
}

private struct EventButtons: View {
    let event: EventAttributes
    let done: Bool

    var body: some View {
        HStack(spacing: 8) {
            if done {
                Text("✓ In your log").font(.headline)
            } else {
                Button(intent: OpenURLIntent(event.directions)) { pill("Go", filled: false) }
                Button(intent: EventDoneIntent(day: event.day, id: event.id)) { pill("Done", filled: true) }
            }
        }
        .buttonStyle(.plain)
    }

    private func pill(_ text: String, filled: Bool) -> some View {
        Text(text).font(.system(size: 15, weight: .semibold))
            .foregroundStyle(filled ? Color.pondBackground : Color.ink)
            .padding(.horizontal, 18).frame(minHeight: 36)
            .background(Capsule().fill(filled ? Color.ink : Color.pondBackground))
    }
}
