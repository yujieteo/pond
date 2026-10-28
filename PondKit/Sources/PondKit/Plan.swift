import Foundation

public enum Weekday: String, CaseIterable, Codable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    public static let workdays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]

    /// From `Calendar.component(.weekday, from:)`, where 1 is Sunday.
    public init(calendarWeekday: Int) {
        self = Weekday.allCases[(calendarWeekday + 5) % 7]
    }
}

public enum Days: Equatable, Sendable {
    case everyDay
    case on(Set<Weekday>)

    public func contains(_ day: Weekday) -> Bool {
        switch self {
        case .everyDay: true
        case .on(let days): days.contains(day)
        }
    }
}

/// One row of the grid: a domain and what each mode means for it.
public struct Domain: Equatable, Sendable {
    public var number: Int
    public var name: String
    public var cells: [Mode: String]
}

/// One thing that a day offers.
public struct Slot: Equatable, Sendable {
    public var text: String
    public var made: String?
    public var domains: [Int]
    public var days: Days
}

/// The weekly part of media-plan.md: the grid and the slots of each day.
/// The monthly, quarterly and yearly lists are reviews, not daily choices, so the parser skips them.
public struct Plan: Equatable, Sendable {
    public var domains: [Domain]
    public var slots: [Slot]

    public func slots(on day: Weekday) -> [Slot] {
        slots.filter { $0.days.contains(day) }
    }

    public init(markdown: String) {
        enum Part { case grid, core, theme, saturday, sunday }
        var part: Part?
        var domains: [Domain] = []
        var slots: [Slot] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("#") {
                part = line.hasPrefix("## 1. The grid") ? .grid : nil
                continue
            }
            if line.hasPrefix("**"), line.hasSuffix("**") {
                part = line.hasPrefix("**Weekday core") ? .core
                    : line.hasPrefix("**Weekday theme slot") ? .theme
                    : line.hasPrefix("**Saturday") ? .saturday
                    : line.hasPrefix("**Sunday") ? .sunday
                    : nil
                continue
            }
            switch part {
            case .grid:
                let cells = Plan.cells(line)
                if cells.count == 6, let number = Int(cells[0]) {
                    let modes: [Mode] = [.home, .live, .takePart, .make]
                    domains.append(Domain(number: number, name: cells[1],
                                          cells: Dictionary(uniqueKeysWithValues: zip(modes, cells[2...]))))
                }
            case .theme:
                let cells = Plan.cells(line)
                if cells.count == 3, let day = Weekday(rawValue: cells[0].lowercased()) {
                    slots.append(Slot(text: cells[1], made: cells[2], domains: Plan.domainNumbers(cells[1]), days: .on([day])))
                }
            case .core, .saturday, .sunday:
                guard line.hasPrefix("- [ ] ") else { continue }
                let text = String(line.dropFirst(6))
                if text.hasPrefix("Monthly slot") { continue }
                let days: Set<Weekday> = part == .core ? Weekday.workdays : part == .saturday ? [.saturday] : [.sunday]
                slots.append(Slot(text: text, made: nil, domains: Plan.domainNumbers(text), days: .on(days)))
            case nil:
                continue
            }
        }
        self.domains = domains
        self.slots = slots
    }

    /// The cells of a table row, or none for a line that is no row.
    static func cells(_ line: String) -> [String] {
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return [] }
        return line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The grid numbers that a slot names, as in "Text (1)".
    static func domainNumbers(_ text: String) -> [Int] {
        text.matches(of: /\((\d{1,2})\)/).compactMap { Int($0.1) }
    }
}
