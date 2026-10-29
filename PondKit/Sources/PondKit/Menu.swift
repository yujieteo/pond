import Foundation

/// One choice of the day's menu (R2), with the entry that "Done" records.
public struct Choice: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case slot
        /// An earlier entry with a fun mark of "good" or "loved it".
        case enjoyed(id: String)
        case notVisited
        /// The active experiment (docs/concepts.md, sync 7). "Done" counts a day and makes no entry.
        case experiment(id: String)
    }

    public var source: Source
    /// The small line above the title, for example "You loved this".
    public var why: String
    public var entry: Entry
}

extension Mode {
    /// The name in the app: "at home", "live", "take part", "make".
    public var label: String {
        switch self {
        case .home: "at home"
        case .live: "live"
        case .takePart: "take part"
        case .make: "make"
        }
    }
}

/// The day's menu: today's slot, one thing enjoyed recently and one place not visited yet (R2).
/// The same day gives the same menu, so the menu does not change while you look at it.
public enum Menu {
    /// An entry comes back as "enjoyed recently" at most once in this number of days (docs/concepts.md, sync 5).
    public static let enjoyedGap = 14

    public static func choices(plan: Plan, journal: Journal, date: Date, calendar: Calendar = .current) -> [Choice] {
        let today = day(date, calendar)
        let weekday = Weekday(calendarWeekday: calendar.component(.weekday, from: date))
        let turn = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        var choices: [Choice] = []

        // The weekday core repeats each workday, so it is the "Every day" row, not a choice.
        let slots = plan.slots(on: weekday).filter { $0.part != .core }
        if !slots.isEmpty {
            let slot = slots[turn % slots.count]
            let (label, what) = parts(slot.text)
            choices.append(Choice(source: .slot, why: "Today's slot · \(label)",
                                  entry: Entry(date: today, title: what, domain: slot.domains.first, mode: .home, slot: slot.text)))
        }

        let gapStart = day(calendar.date(byAdding: .day, value: -enjoyedGap, to: date) ?? date, calendar)
        let enjoyed = journal.records
            .filter { !$0.removed && ($0.fun == .loved || $0.fun == .good) && $0.entry.date < today }
            .filter { $0.offered == nil || $0.offered == today || $0.offered! <= gapStart }
            .max { ($0.fun == .loved ? 1 : 0, $0.entry.date) < ($1.fun == .loved ? 1 : 0, $1.entry.date) }
        if let enjoyed {
            var entry = enjoyed.entry
            entry.date = today
            choices.append(Choice(source: .enjoyed(id: enjoyed.id),
                                  why: enjoyed.fun == .loved ? "You loved this" : "You liked this", entry: entry))
        }

        let year = today.prefix(4)
        let visited = Set(journal.records.filter { !$0.removed && $0.entry.date.hasPrefix(year) }
            .compactMap { record in record.entry.domain.map { "\($0) \(record.entry.mode?.rawValue ?? "")" } })
        let open = plan.domains.flatMap { domain in
            Mode.allCases.compactMap { mode in visited.contains("\(domain.number) \(mode.rawValue)") ? nil : (domain, mode) }
        }
        if !open.isEmpty {
            let (domain, mode) = open[turn % open.count]
            choices.append(notVisited(domain, mode, day: today))
        }
        return choices
    }

    /// The choice of a place not visited yet: the menu's 3rd choice, or an empty cell of the grid.
    public static func notVisited(_ domain: Domain, _ mode: Mode, day: String) -> Choice {
        let first = domain.cells[mode]?.split(separator: ",").first.map(String.init) ?? domain.name
        return Choice(source: .notVisited, why: "Not visited yet · \(domain.name) · \(mode.label)",
                      entry: Entry(date: day, title: capitalized(first), domain: domain.number, mode: mode))
    }

    /// YYYY-MM-DD in the calendar's time zone, as an entry's `date`.
    public static func day(_ date: Date, _ calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// "Text (1): essays, newsletters and saved articles. Skip ..." gives "Text" and "Essays, newsletters and saved articles".
    static func parts(_ text: String) -> (label: String, what: String) {
        guard let colon = text.firstIndex(of: ":") else { return ("", text) }
        let label = String(text[..<colon]).replacing(/\s*\([^)]*\)/, with: "")
        var what = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let stop = what.firstRange(of: ". ") { what = String(what[..<stop.lowerBound]) }
        if what.hasSuffix(".") { what.removeLast() }
        return (label, capitalized(what))
    }

    static func capitalized(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
