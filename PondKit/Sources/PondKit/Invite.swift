import Foundation

/// One day of the invite: its choices (at most 4) and its pick (at most 1).
public struct InviteDay: Codable, Equatable, Sendable {
    /// YYYY-MM-DD, as an entry's `date`.
    public var date: String
    public var choices: [Choice]
    /// The index of the picked choice. A pick is not an entry: only "Done" records (R1).
    public var pick: Int?
    /// "Done" recorded the pick. The widgets then show "In your log".
    public var done = false

    public var picked: Choice? {
        pick.flatMap { choices.indices.contains($0) ? choices[$0] : nil }
    }
}

/// The daily invite (R3, docs/concepts.md, Invite): one notification at the invite time with the day's choices.
/// The phone schedules the notifications of the next `daysAhead` days, so their choices are made when they are scheduled.
public struct Invite: Codable, Equatable, Sendable {
    public static let maxChoices = 4
    public static let daysAhead = 14

    public var hour = 19
    public var minute = 30
    /// Today and the next days, in date order.
    public var days: [InviteDay] = []

    public init() {}

    public subscript(date: String) -> InviteDay? {
        days.first { $0.date == date }
    }

    /// The time of the notification of `date`.
    public func time(of date: String, calendar: Calendar = .current) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute))
    }

    public mutating func setTime(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Makes the choices of each day not yet offered, from today for `daysAhead` days (docs/concepts.md, sync 1).
    /// A day is offered when its notification time is past or when it has a pick: its choices then stay.
    /// An earlier day goes, with no mark. Each "enjoyed recently" choice marks its record in `journal`,
    /// so a record comes back at most once in `Menu.enjoyedGap` days (sync 5).
    public mutating func offer(plan: Plan, journal: inout Journal, now: Date, calendar: Calendar = .current) {
        let today = Menu.day(now, calendar)
        let kept = days.filter { day in
            day.date == today && (day.pick != nil || time(of: day.date, calendar: calendar).map { $0 <= now } ?? false)
        }
        let keptDates = Set(kept.map(\.date))
        for record in journal.records {
            if let offered = record.offered, offered >= today, !keptDates.contains(offered) { journal.offer(record.id, on: nil) }
        }
        days = (0..<Invite.daysAhead).compactMap { ahead in
            guard let date = calendar.date(byAdding: .day, value: ahead, to: now) else { return nil }
            let day = Menu.day(date, calendar)
            if let kept = kept.first(where: { $0.date == day }) { return kept }
            let choices = Array(Menu.choices(plan: plan, journal: journal, date: date, calendar: calendar).prefix(Invite.maxChoices))
            for case .enjoyed(let id) in choices.map(\.source) { journal.offer(id, on: day) }
            return InviteDay(date: day, choices: choices)
        }
    }

    public mutating func pick(_ index: Int, on date: String) {
        change(date) {
            guard $0.choices.indices.contains(index) else { return }
            $0.pick = index
            $0.done = false
        }
    }

    public mutating func unpick(on date: String) {
        change(date) {
            $0.pick = nil
            $0.done = false
        }
    }

    /// "Done" on the pick: returns the entry to record, once.
    public mutating func done(on date: String) -> Entry? {
        guard let index = days.firstIndex(where: { $0.date == date }), !days[index].done,
              let entry = days[index].picked?.entry else { return nil }
        days[index].done = true
        return entry
    }

    private mutating func change(_ date: String, _ body: (inout InviteDay) -> Void) {
        if let index = days.firstIndex(where: { $0.date == date }) { body(&days[index]) }
    }
}
