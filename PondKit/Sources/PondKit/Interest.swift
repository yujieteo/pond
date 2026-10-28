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
