import Foundation

/// A first guess at the grid cell of a shared link, from its host. The share sheet shows
/// the guess, and you change it with one tap, so a wrong guess costs little.
public enum HostDomain {
    public struct Guess: Equatable, Sendable {
        public var domain: Int?
        public var mode: Mode
    }

    /// Host (without "www.") to grid domain and mode. A subdomain gets the guess of its parent.
    static let table: [String: Guess] = [
        "arxiv.org": Guess(domain: 13, mode: .home),
        "archive.org": Guess(domain: 1, mode: .home),
        "goodreads.com": Guess(domain: 1, mode: .home),
        "substack.com": Guess(domain: 1, mode: .home),
        "open.spotify.com": Guess(domain: 2, mode: .home),
        "music.apple.com": Guess(domain: 2, mode: .home),
        "bandcamp.com": Guess(domain: 2, mode: .home),
        "podcasts.apple.com": Guess(domain: 3, mode: .home),
        "youtube.com": Guess(domain: 5, mode: .home),
        "youtu.be": Guess(domain: 5, mode: .home),
        "netflix.com": Guess(domain: 5, mode: .home),
        "viki.com": Guess(domain: 5, mode: .home),
        "letterboxd.com": Guess(domain: 5, mode: .home),
        "store.steampowered.com": Guess(domain: 7, mode: .home),
        "boardgamegeek.com": Guess(domain: 7, mode: .home),
        "lichess.org": Guess(domain: 7, mode: .takePart),
        "chess.com": Guess(domain: 7, mode: .takePart),
        "sec.gov": Guess(domain: 15, mode: .home),
        "patents.google.com": Guess(domain: 15, mode: .home),
        "standards.ieee.org": Guess(domain: 15, mode: .home),
        "news.ycombinator.com": Guess(domain: 16, mode: .home),
        "reddit.com": Guess(domain: 16, mode: .home),
        "x.com": Guess(domain: 16, mode: .home),
        "twitter.com": Guess(domain: 16, mode: .home),
        "eventbrite.com": Guess(domain: nil, mode: .live),
        "eventbrite.sg": Guess(domain: nil, mode: .live),
        "peatix.com": Guess(domain: nil, mode: .live),
        "meetup.com": Guess(domain: 17, mode: .live),
    ]

    public static func guess(for url: URL) -> Guess? {
        guard var host = url.host()?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while true {
            if let guess = table[host] { return guess }
            guard let dot = host.firstIndex(of: ".") else { return nil }
            host = String(host[host.index(after: dot)...])
        }
    }
}
