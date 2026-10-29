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

    /// Puts the live event `choice` in place of the day's "not visited" choice or of its earlier event, when that choice
    /// is not the pick. When it is the pick, the event comes after it, if the day has room. With no `choice`, the earlier event goes, if it is not the pick: its event was removed.
    mutating func live(_ choice: Choice?) {
        let old = choices.firstIndex { if case .event = $0.source { true } else { false } }
        if let old, choices[old] == choice || pick == old { return }
        guard let choice else {
            if let old { choices.remove(at: old); if let p = pick, p > old { pick = p - 1 } }
            return
        }
        if let index = old ?? choices.firstIndex(where: { $0.source == .notVisited }), pick != index {
            choices[index] = choice
        } else if choices.count < Invite.maxChoices {
            choices.append(choice)
        }
    }

    /// Puts `choice` in place of the day's experiment choice, as the last choice. A pick of a choice that goes is cleared.
    mutating func experiment(_ choice: Choice?) {
        let old = choices.firstIndex { if case .experiment = $0.source { true } else { false } }
        if let old, choices[old] == choice { return }
        if let old {
            choices.remove(at: old)
            if pick == old { pick = nil; done = false }
        }
        guard let choice else { return }
        if choices.count == Invite.maxChoices {
            if pick == choices.count - 1 { return }
            choices.removeLast()
        }
        choices.append(choice)
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
    /// A day is offered when its notification time is past or when it has a pick: today's choices then stay.
    /// An earlier day goes, with no mark. Each "enjoyed recently" choice of an offered day marks its record in `journal`,
    /// so a record comes back at most once in `Menu.enjoyedGap` days (sync 5). The days not yet offered mark a copy only.
    /// The active experiment of `experiments` is the last choice of each day of its run, also of an offered day (sync 7).
    /// "One paper" offers a different paper on each day not yet read, and a saved live event is the live choice of its day,
    /// also of an offered day (sync 12).
    public mutating func offer(plan: Plan, journal: inout Journal, experiments: ExperimentLog = ExperimentLog(),
                               interests: Interests = Interests(), events: [Event] = [], now: Date,
                               calendar: Calendar = .current) {
        let today = Menu.day(now, calendar)
        let offered = days.filter { day in
            day.pick != nil || time(of: day.date, calendar: calendar).map { $0 <= now } ?? false
        }
        for day in offered {
            for case .enjoyed(let id) in day.choices.map(\.source) { journal.offer(id, on: day.date) }
        }
        let kept = offered.filter { $0.date == today }
        var scratch = journal
        var papers: [String: String] = [:]
        days = (0..<Invite.daysAhead).compactMap { ahead in
            guard let date = calendar.date(byAdding: .day, value: ahead, to: now) else { return nil }
            let day = Menu.day(date, calendar)
            let choices = kept.first { $0.date == day }?.choices
                ?? Array(Menu.choices(plan: plan, journal: scratch, date: date, calendar: calendar, interests: interests,
                                      events: events, offered: papers).prefix(Invite.maxChoices))
            for choice in choices {
                if case .enjoyed(let id) = choice.source { scratch.offer(id, on: day) }
                if let interest = choice.entry.interest, let link = choice.entry.link { papers[link.absoluteString] = interest }
            }
            return kept.first { $0.date == day } ?? InviteDay(date: day, choices: choices)
        }
        for index in days.indices {
            days[index].live(Event.on(days[index].date, in: events, calendar: calendar).first?.choice(calendar))
            days[index].experiment(experiments.choice(on: days[index].date))
        }
    }

    /// Picks `choice` on `date`, in place of the day's "not visited" choice: an empty cell of the grid.
    public mutating func pick(_ choice: Choice, on date: String) {
        change(date) {
            let index = $0.choices.firstIndex { $0.source == .notVisited }
                ?? ($0.choices.count < Invite.maxChoices ? $0.choices.count : $0.choices.count - 1)
            if index == $0.choices.count { $0.choices.append(choice) } else { $0.choices[index] = choice }
            $0.pick = index
            $0.done = false
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
