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
    /// The list or the table of media-plan.md that has the slot.
    public enum Part: Sendable {
        /// The weekday core: the "Every day" row, not a choice of the menu.
        case core, theme, saturday, sunday
        /// The list that the plan editor adds to the file.
        case added
    }

    public var text: String
    public var made: String?
    public var domains: [Int]
    public var days: Days
    public var part: Part
    /// The line of the slot in the file, from 0.
    public var line: Int

    public var weekdays: Set<Weekday> {
        switch days {
        case .everyDay: Set(Weekday.allCases)
        case .on(let days): days
        }
    }
}

/// The weekly part of media-plan.md: the grid and the slots of each day.
/// The monthly, quarterly and yearly lists are reviews, not daily choices, so the parser skips them.
/// A slot on other days than its list has a marker at the end, for example "(days: Mon Fri)".
public struct Plan: Equatable, Sendable {
    public var domains: [Domain]
    public var slots: [Slot]
    public private(set) var markdown: String

    /// The heading of the list of the slots that the plan editor adds.
    static let addedHeading = "**Added in the app**"

    public func slots(on day: Weekday) -> [Slot] {
        slots.filter { $0.days.contains(day) }
    }

    public init(markdown: String) {
        enum Part { case grid, slots(Slot.Part) }
        var part: Part?
        var domains: [Domain] = []
        var slots: [Slot] = []

        for (number, line) in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated() {
            if line.hasPrefix("#") {
                part = line.hasPrefix("## 1. The grid") ? .grid : nil
                continue
            }
            if line.hasPrefix("**"), line.hasSuffix("**") {
                part = line.hasPrefix("**Weekday core") ? .slots(.core)
                    : line.hasPrefix("**Weekday theme slot") ? .slots(.theme)
                    : line.hasPrefix("**Saturday") ? .slots(.saturday)
                    : line.hasPrefix("**Sunday") ? .slots(.sunday)
                    : line == Plan.addedHeading ? .slots(.added)
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
            case .slots(.theme):
                let cells = Plan.cells(line)
                if cells.count == 3, let day = Weekday(rawValue: cells[0].lowercased()) {
                    let (text, days) = Plan.marker(cells[1])
                    slots.append(Slot(text: text, made: cells[2], domains: Plan.domainNumbers(text), days: .on(days ?? [day]),
                                      part: .theme, line: number))
                }
            case .slots(let list):
                guard line.hasPrefix("- [ ] ") else { continue }
                let (text, days) = Plan.marker(String(line.dropFirst(6)))
                if text.hasPrefix("Monthly slot") { continue }
                slots.append(Slot(text: text, made: nil, domains: Plan.domainNumbers(text),
                                  days: .on(days ?? Plan.listDays(list)), part: list, line: number))
            case nil:
                continue
            }
        }
        self.domains = domains
        self.slots = slots
        self.markdown = markdown
    }

    // MARK: the plan editor (docs/concepts.md, Plan)

    /// Changes the text of a slot in place. The marker of its days stays.
    public mutating func editSlot(_ index: Int, text: String) {
        var slot = slots[index]
        slot.text = Plan.oneLine(text)
        replace(slot)
    }

    public mutating func setDays(_ index: Int, _ days: Set<Weekday>) {
        var slot = slots[index]
        slot.days = .on(days)
        replace(slot)
    }

    /// Adds a slot at the end of the list "Added in the app". The first added slot makes the list, after the list or the table of the last slot.
    public mutating func addSlot(_ text: String, days: Set<Weekday>) {
        var lines = self.lines
        let slot = Slot(text: Plan.oneLine(text), made: nil, domains: [], days: .on(days), part: .added, line: 0)
        if let last = slots.last(where: { $0.part == .added }) {
            lines.insert(Plan.line(slot, was: ""), at: last.line + 1)
        } else if let heading = lines.firstIndex(of: Plan.addedHeading) {
            lines.insert(contentsOf: ["", Plan.line(slot, was: "")], at: heading + 1)
        } else {
            var after = slots.last.map { $0.line + 1 } ?? lines.count
            while after < lines.count, !lines[after].trimmingCharacters(in: .whitespaces).isEmpty,
                  !lines[after].hasPrefix("#"), !lines[after].hasPrefix("**") {
                after += 1
            }
            lines.insert(contentsOf: ["", Plan.addedHeading, "", Plan.line(slot, was: "")], at: after)
        }
        self = Plan(markdown: lines.joined(separator: "\n"))
    }

    public mutating func removeSlot(_ index: Int) {
        var lines = self.lines
        let start = slots[index].line
        var end = start + 1
        while end < lines.count, lines[end].first?.isWhitespace == true { end += 1 }
        lines.removeSubrange(start..<end)
        self = Plan(markdown: lines.joined(separator: "\n"))
    }

    private var lines: [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private mutating func replace(_ slot: Slot) {
        var lines = self.lines
        lines[slot.line] = Plan.line(slot, was: lines[slot.line])
        self = Plan(markdown: lines.joined(separator: "\n"))
    }

    /// The line of `slot` in the file. A table row keeps its day and what you make.
    static func line(_ slot: Slot, was: String) -> String {
        if slot.part == .theme {
            var cells = cells(was)
            let day = Weekday(rawValue: cells[0].lowercased()).map { Set([$0]) }
            cells[1] = slot.text.replacingOccurrences(of: "|", with: "/") + marker(slot.weekdays, default: day)
            return "| " + cells.joined(separator: " | ") + " |"
        }
        return "- [ ] " + slot.text + marker(slot.weekdays, default: slot.part == .added ? nil : listDays(slot.part))
    }

    /// The days of a slot with no marker.
    static func listDays(_ part: Slot.Part) -> Set<Weekday> {
        switch part {
        case .core: Weekday.workdays
        case .saturday: [.saturday]
        case .sunday: [.sunday]
        case .theme, .added: []
        }
    }

    /// " (days: Mon Fri)", or nothing when the days are the days of the list.
    static func marker(_ days: Set<Weekday>, default: Set<Weekday>?) -> String {
        if days == `default` { return "" }
        if days.count == 7 { return " (days: every day)" }
        if days.isEmpty { return " (days: none)" }
        return " (days: " + Weekday.allCases.filter(days.contains).map { $0.rawValue.prefix(3).capitalized }.joined(separator: " ") + ")"
    }

    /// The text without its marker, and the days of the marker.
    static func marker(_ text: String) -> (String, Set<Weekday>?) {
        guard let match = text.firstMatch(of: /\s*\(days: ([a-z ]+)\)$/.ignoresCase()) else { return (text, nil) }
        let words = match.1.lowercased().split(separator: " ")
        let days: Set<Weekday> = match.1.lowercased() == "every day" ? Set(Weekday.allCases)
            : Set(words.compactMap { word in Weekday.allCases.first { $0.rawValue.hasPrefix(word) } })
        return (String(text[..<match.range.lowerBound]), days)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
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
