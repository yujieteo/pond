import AppIntents
import PondKit
import SwiftUI
import WidgetKit

/// The widgets (R16, #widget in the mock-up): the same choices or the same pick as the notification, with "Done".
@main
struct PondWidgets: WidgetBundle {
    var body: some Widget {
        InviteWidget()
        EventActivityWidget()
    }
}

struct InviteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "invite", provider: Provider()) { day in
            InviteView(day: day.day).containerBackground(Color.card, for: .widget)
        }
        .configurationDisplayName("What do you want today?")
        .description("Today's choices, and \"Done\" for your pick.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct DayEntry: TimelineEntry {
    var date: Date
    var day: InviteDay?
}

/// The app writes the next 14 days to the App Group, so the timeline has one entry at the start of each day.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> DayEntry { DayEntry(date: .now, day: nil) }

    func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
        completion(DayEntry(date: .now, day: SharedInvite.load()[Menu.day(.now)]))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
        let invite = SharedInvite.load()
        let today = Calendar.current.startOfDay(for: .now)
        let entries = (0..<Invite.daysAhead).compactMap { ahead -> DayEntry? in
            guard let start = Calendar.current.date(byAdding: .day, value: ahead, to: today) else { return nil }
            return DayEntry(date: max(start, .now), day: invite[Menu.day(start)])
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct InviteView: View {
    var day: InviteDay?
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular { lockScreen } else { homeScreen }
    }

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let day, day.done {
                Text("In your log ✓").font(.headline)
                Spacer(minLength: 0)
            } else if let day, let pick = day.picked {
                Text("Today: \(pick.entry.title)").font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Button(intent: DoneIntent(day: day.date)) { row("✓ Done") }
                Button(intent: UnpickIntent(day: day.date)) { row("Something else") }
            } else {
                Text("What do you want today?").font(.headline).padding(.bottom, 4)
                let rows = family == .systemLarge ? Invite.maxChoices : 3
                ForEach(Array((day?.choices ?? []).prefix(rows).enumerated()), id: \.offset) { index, choice in
                    Button(intent: PickIntent(day: day!.date, index: index)) { row("\(choice.icon) \(choice.entry.title)") }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).lineLimit(1)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }

    /// The Lock Screen widget: the pick and "Done", or today's choices.
    private var lockScreen: some View {
        HStack(spacing: 6) {
            if let day, day.done {
                Text("✓ In your log").font(.headline)
            } else if let day, let pick = day.picked {
                Text("\(pick.icon) \(pick.entry.title)").font(.headline).lineLimit(2)
                Spacer(minLength: 0)
                Button(intent: DoneIntent(day: day.date)) {
                    Text("Done").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(AccessoryWidgetBackground().clipShape(Capsule()))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("What do you want today?").font(.headline).widgetAccentable()
                    ForEach(Array((day?.choices ?? []).prefix(2).enumerated()), id: \.offset) { index, choice in
                        Button(intent: PickIntent(day: day!.date, index: index)) {
                            Text("\(choice.icon) \(choice.entry.title)").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
