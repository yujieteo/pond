import Foundation

/// The private fun mark of an entry (R11). It stays on the phone.
public enum Fun: String, Codable, CaseIterable, Sendable {
    case little = "a little", good, loved = "loved it"
}

/// One entry as the phone keeps it: the public entry, the private fields, and what the nodes have.
public struct Record: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The newest revision on the phone.
    public var rev: Int
    /// The newest revision that a node (the server or the desktop) accepted; 0 if none.
    public var sentRev = 0
    /// The phone sent a change of this record at least once, so a node can have it, also without a reply.
    public var tried = false
    /// The server refused `rev` with 400 or 413. A new edit sends again.
    public var refused = false
    public var entry: Entry
    /// The phone sends the removal after `removeAt`, so that "Undo" never needs the server.
    public var removeAt: Date?
    public var fun: Fun?
    /// The day (YYYY-MM-DD) on which the menu last offered this entry as "enjoyed recently".
    public var offered: String?

    public var removed: Bool { removeAt != nil }
    public var waiting: Bool { rev > sentRev && !refused }
}

extension Record {
    /// A journal.json from before `tried` has no `tried` key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rev = try container.decode(Int.self, forKey: .rev)
        sentRev = try container.decode(Int.self, forKey: .sentRev)
        tried = try container.decodeIfPresent(Bool.self, forKey: .tried) ?? false
        refused = try container.decode(Bool.self, forKey: .refused)
        entry = try container.decode(Entry.self, forKey: .entry)
        removeAt = try container.decodeIfPresent(Date.self, forKey: .removeAt)
        fun = try container.decodeIfPresent(Fun.self, forKey: .fun)
        offered = try container.decodeIfPresent(String.self, forKey: .offered)
    }
}

/// What the reply of a node means to the outbox (docs/protocol.md, The replies). The desktop gives the replies of the server.
public enum Reply: Equatable, Sendable {
    /// 201, or 200 for a retry: the node has this revision.
    case accepted
    /// 409: the node has the revision `saved`, which is not lower.
    case conflict(saved: Int)
    /// 400 or 413: no node ever accepts this body.
    case refused
    /// No reply, or a reply that can change later (403 until the key is enrolled, 5xx): send again later.
    case later

    public init(status: Int, body: String) {
        switch status {
        case 200, 201: self = .accepted
        case 409:
            if let match = body.firstMatch(of: /the server has rev (\d+)/), let saved = Int(match.1) {
                self = .conflict(saved: saved)
            } else {
                self = .later
            }
        case 400, 413: self = .refused
        default: self = .later
        }
    }
}

/// The entries on the phone. The outbox is the set of records with a revision that no node has acknowledged yet.
public struct Journal: Codable, Equatable, Sendable {
    public var records: [Record] = []

    public init() {}

    public subscript(id: String) -> Record? {
        records.first { $0.id == id }
    }

    @discardableResult
    public mutating func record(_ entry: Entry) -> String {
        let id = UUID().uuidString
        records.append(Record(id: id, rev: 1, entry: entry))
        return id
    }

    public mutating func edit(_ id: String, entry: Entry) {
        change(id) {
            guard $0.entry != entry else { return }
            $0.entry = entry
            $0.rev += 1
            $0.refused = false
        }
    }

    public mutating func mark(_ id: String, fun: Fun?) {
        change(id) { $0.fun = fun }
    }

    public mutating func offer(_ id: String, on day: String?) {
        change(id) { $0.offered = day }
    }

    /// The entry goes from the screen at once. The phone sends the removal at `at`.
    public mutating func remove(_ id: String, at: Date) {
        change(id) {
            guard !$0.removed else { return }
            $0.removeAt = at
            $0.rev += 1
            $0.refused = false
        }
    }

    /// Undo of `remove`, while the removal is not sent.
    public mutating func restore(_ id: String) {
        change(id) {
            guard $0.removed, $0.sentRev < $0.rev else { return }
            $0.removeAt = nil
            $0.rev -= 1
        }
    }

    /// The changes to send now, signed by `key`. A removal of an entry that the phone never tried to send is not sent:
    /// the record goes.
    public mutating func outbox(now: Date, key: String) -> [Change] {
        records.removeAll { $0.removed && !$0.tried && $0.removeAt! <= now }
        return records.compactMap { record in
            guard record.waiting else { return nil }
            if let removeAt = record.removeAt {
                return removeAt <= now ? .remove(id: record.id, rev: record.rev, key: key) : nil
            }
            return .put(record.entry, id: record.id, rev: record.rev, key: key)
        }
    }

    /// The reply of a node to `change`. Returns true if the record waits for a send at once: after a 409,
    /// the phone's change gets the revision after the node's, because the phone has the newest change.
    @discardableResult
    public mutating func apply(_ reply: Reply, to change: Change) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == change.id }) else { return false }
        records[index].tried = true
        switch reply {
        case .accepted:
            records[index].sentRev = max(records[index].sentRev, change.rev)
            if records[index].removed, !records[index].waiting { records.remove(at: index) }
            return false
        case .conflict(let saved):
            guard records[index].rev <= saved else { return false }
            records[index].rev = saved + 1
            records[index].sentRev = saved
            return true
        case .refused:
            if records[index].rev == change.rev { records[index].refused = true }
            return false
        case .later:
            return false
        }
    }

    private mutating func change(_ id: String, _ body: (inout Record) -> Void) {
        if let index = records.firstIndex(where: { $0.id == id }) { body(&records[index]) }
    }
}

public enum Outbox {
    public typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    /// The nodes that take a save, in the order of the tries: the server, then the desktop if `fallback` is on and
    /// `desktop` is an http or https URL. The fallback stays off until phase 5 of docs/store.md: in shadow mode, the site
    /// does not show a save that only the desktop took.
    public static func nodes(server: URL, desktop: String, fallback: Bool) -> [URL] {
        guard fallback, let url = URL(string: desktop.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme),
              url.host() != nil
        else { return [server] }
        return [server, url]
    }

    /// Sends each signed change once, to the first node of `nodes` that is up: the server, then the desktop over the VPN.
    /// A node is down if it gives no reply or a 5xx. After a node is down, the next changes start at the node after it,
    /// so that each change does not wait for a node that is down again. Returns the replies in the same sequence.
    public static func send(_ changes: [SignedChange], nodes: [URL], transport: Transport) async -> [Reply] {
        var replies: [Reply] = []
        var first = 0
        for change in changes {
            var reply = Reply.later
            while first < nodes.count {
                if let (status, body) = try? await transport(change.request(server: nodes[first])), status < 500 {
                    reply = Reply(status: status, body: String(decoding: body, as: UTF8.self))
                    break
                }
                first += 1
            }
            replies.append(reply)
        }
        return replies
    }

    /// The transport of the app.
    public static let urlSession: Transport = { request in
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}
