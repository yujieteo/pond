import Foundation

/// A live event saved for its day (R15, docs/concepts.md, Event). On that day it is the live choice of the menu.
/// It stays on the phone; only "Done" on it makes a public entry.
public struct Event: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var place: String
    /// For example "free" or "S$15".
    public var cost: String?
    public var link: URL?
    public var domain: Int?

    public init(id: String = UUID().uuidString, title: String, start: Date, place: String, cost: String? = nil,
                link: URL? = nil, domain: Int? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.place = place
        self.cost = cost
        self.link = link
        self.domain = domain
    }

    /// "20:00" in the calendar's time zone.
    public func time(_ calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: start)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The live choice of its day: "Live · 20:00 · free". The app adds the travel time when it shows the choice.
    public func choice(_ calendar: Calendar = .current) -> Choice {
        let why = (["Live", time(calendar)] + [cost].compactMap { $0 }).joined(separator: " · ")
        return Choice(source: .event(id: id), why: why,
                      entry: Entry(date: Menu.day(start, calendar), title: title, link: link, domain: domain, mode: .live))
    }

    /// "Go": the directions to the place in Maps.
    public var directions: URL {
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [URLQueryItem(name: "daddr", value: place)]
        return parts.url!
    }

    /// The events of `date` (YYYY-MM-DD), earliest first.
    public static func on(_ date: String, in events: [Event], calendar: Calendar = .current) -> [Event] {
        events.filter { Menu.day($0.start, calendar) == date }.sorted { $0.start < $1.start }
    }
}
