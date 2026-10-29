import Foundation

/// A topic that "One paper" can come from (docs/concepts.md, Interest).
public struct Interest: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        /// An arXiv category, for example "physics.optics".
        case arxiv(String)
        /// A journal's RSS or Atom feed.
        case feed(URL)

        public var url: URL {
            switch self {
            case .arxiv(let category): URL(string: "https://rss.arxiv.org/atom/\(category)")!
            case .feed(let url): url
            }
        }
    }

    public var name: String
    public var sources: [Source]
    /// Old papers and standards that you add by hand, offered on the "old" days.
    public var classics: [Paper]
    /// The date of the last entry from this interest; nil if there is none.
    public var lastRead: Date?

    public init(name: String, sources: [Source] = [], classics: [Paper] = [], lastRead: Date? = nil) {
        self.name = name
        self.sources = sources
        self.classics = classics
        self.lastRead = lastRead
    }
}

/// A paper from a feed or from a hand list. `id` is the link, which the "read" set holds.
public struct Paper: Codable, Equatable, Sendable {
    public var title: String
    public var link: URL
    public var published: Date?
    public var id: String { link.absoluteString }

    public init(title: String, link: URL, published: Date? = nil) {
        self.title = title
        self.link = link
        self.published = published
    }
}

public enum OnePaper {
    /// Takes the interest read least lately that has a paper to offer. On an old day it offers
    /// the first unread classic; on other days the newest unread paper of its feeds.
    /// `papers` holds the fetched feed items of each interest, by name.
    public static func pick(interests: [Interest], papers: [String: [Paper]], read: Set<String>,
                            today: Weekday, oldDays: Set<Weekday>) -> (interest: Interest, paper: Paper)? {
        let order = interests.enumerated().sorted { a, b in
            switch (a.element.lastRead, b.element.lastRead) {
            case let (x?, y?) where x != y: x < y
            case (nil, _?): true
            case (_?, nil): false
            default: a.offset < b.offset
            }
        }.map(\.element)
        for interest in order {
            let candidates = oldDays.contains(today)
                ? interest.classics
                : (papers[interest.name] ?? []).sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            if let paper = candidates.first(where: { !read.contains($0.id) }) {
                return (interest, paper)
            }
        }
        return nil
    }
}

/// Reads the items of an RSS 2.0 or an Atom feed. Items with no title or no link are left out.
public final class FeedParser: NSObject, XMLParserDelegate {
    private var papers: [Paper] = []
    private var title: String?
    private var link: String?
    private var date: String?
    private var text = ""
    private var inItem = false

    public static func parse(_ data: Data) -> [Paper] {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.papers
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                       qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "item" || name == "entry" {
            inItem = true
            title = nil
            link = nil
            date = nil
        } else if inItem, name == "link", let href = attributes["href"], attributes["rel"] ?? "alternate" == "alternate" {
            link = href
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": title = value
        case "link" where !value.isEmpty: link = value
        case "pubDate", "published", "updated", "dc:date": date = date ?? value
        case "item", "entry":
            inItem = false
            if let title, let link, let url = URL(string: link) {
                papers.append(Paper(title: title, link: url, published: date.flatMap(FeedParser.date)))
            }
        default: break
        }
    }

    static func date(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return rfc822.date(from: text)
    }
}

/// The interests on the phone: the topics, the weekdays marked "old", and the papers last fetched from their feeds
/// (docs/concepts.md, Interest). The journal holds the rest: an entry with an interest is a paper read on its date.
public struct Interests: Codable, Equatable, Sendable {
    public var topics: [Interest]
    public var oldDays: Set<Weekday> = []
    /// The items of each interest's feeds, by interest name, from the last fetch.
    public var papers: [String: [Paper]] = [:]
    public var fetched: Date?

    public init(topics: [Interest] = [], oldDays: Set<Weekday> = []) {
        self.topics = topics
        self.oldDays = oldDays
    }

    /// The first interests, from the examples of R14. Each one is a start: rename it, or change its feeds.
    public static let starter = Interests(topics: [
        Interest(name: "Advanced packaging", sources: [.arxiv("physics.app-ph")]),
        Interest(name: "Math", sources: [.arxiv("math.HO")]),
        Interest(name: "Aerospace structures", sources: [.arxiv("physics.class-ph")]),
        Interest(name: "Biology", sources: [.arxiv("q-bio.PE")]),
    ])

    /// "One paper" on `date` (docs/concepts.md, sync 13). The last read date of each interest and the read papers come
    /// from the entries of `journal`. `offered` holds the papers of the days before `date` that are not read yet,
    /// so that the next days of the invite offer other papers.
    public func paper(on date: String, weekday: Weekday, journal: Journal, offered: [String: String] = [:])
        -> (interest: Interest, paper: Paper)? {
        let papers = journal.records.filter { !$0.removed && $0.entry.interest != nil }
        let read = Set(papers.compactMap { $0.entry.link?.absoluteString }).union(offered.keys)
        let topics = topics.map { topic in
            var topic = topic
            let days = papers.filter { $0.entry.interest == topic.name }.map(\.entry.date)
                + offered.filter { _, name in name == topic.name }.map { _ in date }
            topic.lastRead = days.max().flatMap(Interests.date)
            return topic
        }
        return OnePaper.pick(interests: topics, papers: self.papers, read: read, today: weekday, oldDays: oldDays)
    }

    /// The source of a paper for its choice line: "arXiv", "classic" or the host of the link.
    public func origin(of paper: Paper, in interest: Interest) -> String {
        if interest.classics.contains(paper) { return "classic" }
        let host = paper.link.host()?.replacing(/^www\./, with: "") ?? ""
        return host.hasSuffix("arxiv.org") ? "arXiv" : host
    }

    /// The text of the field "arXiv category or feed link": a web link is a feed, other text is an arXiv category.
    public static func source(_ text: String) -> Interest.Source? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), ["http", "https"].contains(url.scheme), url.host() != nil { return .feed(url) }
        return text.wholeMatch(of: /[a-z-]+(\.[A-Za-z-]+)?/) == nil ? nil : .arxiv(text)
    }

    /// Midnight UTC of a YYYY-MM-DD date. Only the sequence of the dates counts.
    static func date(_ day: String) -> Date? {
        Run.number(day).map { Date(timeIntervalSince1970: TimeInterval($0) * 86400) }
    }
}

extension Interest.Source {
    /// The text of the source in the app: the arXiv category, or the feed link.
    public var text: String {
        switch self {
        case .arxiv(let category): category
        case .feed(let url): url.absoluteString
        }
    }
}

extension Slot {
    /// A slot that names "one paper" or "one journal paper" offers a paper from an interest (R14).
    /// The captain sets the days of "One paper" with the days of this slot.
    public var isOnePaper: Bool {
        text.firstMatch(of: /\bone (journal )?paper\b/.ignoresCase()) != nil
    }
}
