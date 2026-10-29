import Foundation

/// One cell of the yearly grid: a domain and a mode.
public struct Cell: Hashable, Sendable {
    public var domain: Int
    public var mode: Mode

    public init(domain: Int, mode: Mode) {
        self.domain = domain
        self.mode = mode
    }
}

/// Where you have been in a year: the entries of each cell of 17 domains × 4 modes (docs/concepts.md, Grid).
/// The grid has no state of its own. A cell with no entry is a place not visited yet.
public enum Grid {
    /// The entries of each filled cell in `year` (YYYY), oldest first. An entry with no domain or no mode is in no cell.
    public static func entries(_ journal: Journal, year: String) -> [Cell: [Record]] {
        var cells: [Cell: [Record]] = [:]
        for record in journal.records where !record.removed && record.entry.date.hasPrefix(year + "-") {
            guard let domain = record.entry.domain, let mode = record.entry.mode else { continue }
            cells[Cell(domain: domain, mode: mode), default: []].append(record)
        }
        return cells
    }

    /// The years that have an entry, and `current`, newest first.
    public static func years(_ journal: Journal, current: String) -> [String] {
        Set(journal.records.filter { !$0.removed }.map { String($0.entry.date.prefix(4)) } + [current]).sorted(by: >)
    }
}
