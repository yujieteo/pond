import PondKit
import UserNotifications

/// The daily notification of the invite (R3): "What do you want today?" with the day's choices as buttons.
/// A pick changes it in place to the pick, "Done" and "Something else", with no sound (docs/concepts.md, sync 2).
/// Ignored, it stays until it is cleared: there is no second notification.
enum InviteNotifications {
    static let picked = "invite.picked"

    static func id(_ day: String) -> String { "invite-\(day)" }

    /// Schedules the notification of each day of `invite`, and changes a delivered one in place.
    static func schedule(_ invite: Invite) async {
        let center = UNUserNotificationCenter.current()
        let today = Menu.day(.now)
        center.setNotificationCategories(categories(invite))

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("invite-") }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix("invite-") }
        // An earlier day goes, with no mark.
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0 < id(today) })

        for day in invite.days {
            if day.done || day.choices.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: [id(day.date)])
                continue
            }
            let content = content(day)
            if let time = invite.time(of: day.date), time > .now {
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: time)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: id(day.date), content: content, trigger: trigger))
            } else if let shown = delivered.first(where: { $0.request.identifier == id(day.date) })?.request.content,
                      shown.title != content.title || shown.categoryIdentifier != content.categoryIdentifier {
                await show(day)
            }
        }
    }

    /// Shows the notification of `day` in place: the same identifier, in the list only, with no sound.
    static func show(_ day: InviteDay) async {
        let content = content(day)
        content.interruptionLevel = .passive
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id(day.date), content: content, trigger: nil))
    }

    static func content(_ day: InviteDay) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let pick = day.picked {
            content.title = "Today: \(pick.entry.title)"
            content.categoryIdentifier = picked
        } else {
            content.title = "What do you want today?"
            content.categoryIdentifier = "invite.\(day.date)"
        }
        content.userInfo = ["day": day.date]
        content.threadIdentifier = "invite"
        return content
    }

    /// The buttons of a notification come from its category, so each day has a category with its choices.
    static func categories(_ invite: Invite) -> Set<UNNotificationCategory> {
        var categories: Set<UNNotificationCategory> = [UNNotificationCategory(identifier: picked, actions: [
            UNNotificationAction(identifier: "done", title: "✓ Done", options: [.authenticationRequired]),
            UNNotificationAction(identifier: "unpick", title: "Something else"),
        ], intentIdentifiers: [])]
        for day in invite.days {
            let actions = day.choices.enumerated().map { index, choice in
                UNNotificationAction(identifier: "pick.\(index)", title: "\(choice.icon) \(choice.entry.title)")
            }
            categories.insert(UNNotificationCategory(identifier: "invite.\(day.date)", actions: actions, intentIdentifiers: []))
        }
        return categories
    }

    /// A tap on a button of the notification. The app runs in the background for it.
    @MainActor
    static func handle(action: String, day: String) async {
        let store = Store.shared
        switch action {
        case "done": store.done(on: day)
        case "unpick": store.unpick(on: day)
        default:
            if action.hasPrefix("pick."), let index = Int(action.dropFirst(5)) { store.pick(index, on: day) }
        }
        await store.finish()
        // The system removes a notification when one of its buttons is tapped: a pick or "Something else" shows it again.
        if action != "done", let day = store.invite[day], !day.done { await show(day) }
    }
}
