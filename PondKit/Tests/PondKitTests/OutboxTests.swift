import CryptoKit
import Foundation
import Testing
@testable import PondKit

private let paper = Entry(date: "2026-10-28", title: "a paper", domain: 13, mode: .home)
private let now = Date(timeIntervalSince1970: 1_793_000_000)

@Test func repliesFollowTheProtocol() {
    #expect(Reply(status: 201, body: "") == .accepted)
    #expect(Reply(status: 200, body: "") == .accepted)
    #expect(Reply(status: 409, body: "the server has rev 7\n") == .conflict(saved: 7))
    #expect(Reply(status: 400, body: "") == .refused)
    #expect(Reply(status: 413, body: "") == .refused)
    #expect(Reply(status: 403, body: "") == .later)
    #expect(Reply(status: 502, body: "") == .later)
}

@Test func anEntryWaitsUntilTheServerAcceptsIt() {
    var journal = Journal()
    let id = journal.record(paper)
    let first = journal.outbox(now: now, key: "phone")
    #expect(first == [.put(paper, id: id, rev: 1, key: "phone")])

    journal.apply(.later, to: first[0])
    let sent1 = journal.outbox(now: now, key: "phone")

    #expect(sent1 == first, "a failed send goes again later")

    journal.apply(.accepted, to: first[0])
    let sent2 = journal.outbox(now: now, key: "phone")

    #expect(sent2.isEmpty)
    #expect(journal[id]?.waiting == false)

    var edited = paper
    edited.title = "a better title"
    journal.edit(id, entry: edited)
    let sent3 = journal.outbox(now: now, key: "phone")

    #expect(sent3 == [.put(edited, id: id, rev: 2, key: "phone")])
}

@Test func aConflictSendsTheRevisionAfterTheServers() {
    var journal = Journal()
    let id = journal.record(paper)
    let change = journal.outbox(now: now, key: "phone")[0]
    let again = journal.apply(.conflict(saved: 4), to: change)
    #expect(again)
    let sent4 = journal.outbox(now: now, key: "phone")

    #expect(sent4 == [.put(paper, id: id, rev: 5, key: "phone")])
}

@Test func aRefusedBodyIsNotSentAgainUntilAnEdit() {
    var journal = Journal()
    let id = journal.record(paper)
    let refused = journal.outbox(now: now, key: "phone")[0]
    journal.apply(.refused, to: refused)
    let sent5 = journal.outbox(now: now, key: "phone")

    #expect(sent5.isEmpty)
    var edited = paper
    edited.title = "fixed"
    journal.edit(id, entry: edited)
    let sent6 = journal.outbox(now: now, key: "phone")

    #expect(sent6.count == 1)
}

@Test func aRemovalWaitsForUndo() {
    var journal = Journal()
    let id = journal.record(paper)
    let put = journal.outbox(now: now, key: "phone")[0]
    journal.apply(.accepted, to: put)

    journal.remove(id, at: now + 6)
    let sent7 = journal.outbox(now: now, key: "phone")

    #expect(sent7.isEmpty, "nothing goes before the Undo time")
    journal.restore(id)
    #expect(journal[id]?.removed == false)
    let sent8 = journal.outbox(now: now + 10, key: "phone")

    #expect(sent8.isEmpty, "Undo needs no server")

    journal.remove(id, at: now + 6)
    let removal = journal.outbox(now: now + 6, key: "phone")
    #expect(removal == [.remove(id: id, rev: 2, key: "phone")])
    journal.apply(.accepted, to: removal[0])
    #expect(journal[id] == nil)
}

@Test func aRemovalOfAnUnsentEntryIsNotSent() {
    var journal = Journal()
    let id = journal.record(paper)
    journal.remove(id, at: now)
    let sent9 = journal.outbox(now: now, key: "phone")

    #expect(sent9.isEmpty)
    #expect(journal[id] == nil)
}

@Test func aRemovalAfterALostReplyIsSent() {
    var journal = Journal()
    let id = journal.record(paper)
    let put = journal.outbox(now: now, key: "phone")[0]
    journal.apply(.later, to: put)

    journal.remove(id, at: now)
    let removal = journal.outbox(now: now, key: "phone")

    #expect(removal == [.remove(id: id, rev: 2, key: "phone")], "the server can have the put without a reply")
}

@Test func aJournalWithoutTriedDecodes() throws {
    var journal = Journal()
    journal.record(paper)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as! [String: [[String: Any]]]
    json["records"]![0].removeValue(forKey: "tried")
    let old = try JSONDecoder().decode(Journal.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old == journal)
}

@Test func theFunMarkIsNotInTheBody() throws {
    var journal = Journal()
    let id = journal.record(paper)
    journal.mark(id, fun: .loved)
    let signed = try SignedChange(journal.outbox(now: now, key: "phone")[0], signer: P256.Signing.PrivateKey())
    #expect(!String(decoding: signed.body, as: UTF8.self).contains("loved"))
}

@Test func menuOffersSlotEnjoyedAndNotVisited() throws {
    let plan = Plan(markdown: try String(contentsOf: Bundle.module.url(forResource: "Fixtures/media-plan", withExtension: "md")!, encoding: .utf8))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 19))!
    let wednesday = calendar.date(byAdding: .day, value: 1, to: tuesday)!

    var journal = Journal()
    var chart = Entry(date: "2026-10-27", title: "Brazil's top 10", domain: 2, mode: .home)
    let id = journal.record(chart)
    journal.mark(id, fun: .loved)

    let menu = Menu.choices(plan: plan, journal: journal, date: wednesday, calendar: calendar)
    #expect(menu.map(\.why) == ["Today's slot · Text", "You loved this", menu[2].why])
    #expect(menu[0].entry.title == "One journal paper (once a month, an old paper or standard of more than 20 years)")
    #expect(menu[0].entry.domain == 1)
    chart.date = "2026-10-28"
    #expect(menu[1].entry == chart)
    #expect(menu[2].source == .notVisited)
    #expect(menu[2].why.hasPrefix("Not visited yet"))
    #expect(!(menu[2].entry.domain == 2 && menu[2].entry.mode == .home), "a visited cell is not offered")

    journal.offer(id, on: "2026-10-28")
    let later = calendar.date(byAdding: .day, value: 2, to: wednesday)!
    #expect(Menu.choices(plan: plan, journal: journal, date: later, calendar: calendar).count == 2, "at most once each 14 days")
    let after = calendar.date(byAdding: .day, value: 14, to: wednesday)!
    #expect(Menu.choices(plan: plan, journal: journal, date: after, calendar: calendar).count == 3)
}

// The fallback: the server first, and the desktop over the VPN when the server is down (docs/store.md, phase 4).

private let server = URL(string: "https://teoyujie.org")!
private let desktop = URL(string: "http://10.0.0.2:8788")!

/// A transport that gives each node's reply from `replies` (nil: no reply), and keeps the host of each request.
private actor Nodes {
    var asked: [String] = []
    let replies: [String: (Int, String)?]

    init(_ replies: [String: (Int, String)?]) { self.replies = replies }

    func reply(_ request: URLRequest) throws -> (status: Int, body: Data) {
        let host = request.url!.host()!
        asked.append(host)
        guard let reply = replies[host] ?? nil else { throw URLError(.cannotConnectToHost) }
        return (reply.0, Data(reply.1.utf8))
    }

    var transport: Outbox.Transport { { request in try await self.reply(request) } }
}

private func signed(_ count: Int) throws -> [SignedChange] {
    var journal = Journal()
    for k in 0..<count { journal.record(Entry(date: "2026-10-28", title: "entry \(k)")) }
    let key = P256.Signing.PrivateKey()
    return try journal.outbox(now: now, key: "phone").map { try SignedChange($0, signer: key) }
}

@Test func theServerComesFirst() async throws {
    let nodes = Nodes(["teoyujie.org": (201, "saved\n"), "10.0.0.2": (201, "saved\n")])
    let replies = await Outbox.send(try signed(2), nodes: [server, desktop], transport: nodes.transport)
    #expect(replies == [.accepted, .accepted])
    #expect(await nodes.asked == ["teoyujie.org", "teoyujie.org"])
}

@Test func theDesktopTakesTheChangesWhenTheServerGivesNoReply() async throws {
    let nodes = Nodes(["teoyujie.org": nil, "10.0.0.2": (201, "saved\n")])
    let replies = await Outbox.send(try signed(3), nodes: [server, desktop], transport: nodes.transport)
    #expect(replies == [.accepted, .accepted, .accepted])
    #expect(await nodes.asked == ["teoyujie.org", "10.0.0.2", "10.0.0.2", "10.0.0.2"], "after the server is down, the next changes go to the desktop first")
}

@Test func theDesktopTakesTheChangeWhenTheServerGivesA5xx() async throws {
    for status in [500, 502, 503, 504] {
        let nodes = Nodes(["teoyujie.org": (status, ""), "10.0.0.2": (409, "the server has rev 3\n")])
        let replies = await Outbox.send(try signed(1), nodes: [server, desktop], transport: nodes.transport)
        #expect(replies == [.conflict(saved: 3)], "a 409 from the desktop names its rev")
        #expect(await nodes.asked == ["teoyujie.org", "10.0.0.2"])
    }
}

@Test func aServerThatRepliesKeepsTheChange() async throws {
    let cases: [(Int, String, Reply)] = [(200, "saved before\n", .accepted), (409, "the server has rev 2\n", .conflict(saved: 2)),
                                         (400, "", .refused), (413, "", .refused), (403, "", .later)]
    for (status, body, want) in cases {
        let nodes = Nodes(["teoyujie.org": (status, body), "10.0.0.2": (201, "saved\n")])
        let replies = await Outbox.send(try signed(1), nodes: [server, desktop], transport: nodes.transport)
        #expect(replies == [want])
        #expect(await nodes.asked == ["teoyujie.org"], "a \(status) from the server does not go to the desktop")
    }
}

@Test func withBothNodesDownEachChangeWaits() async throws {
    let nodes = Nodes(["teoyujie.org": nil, "10.0.0.2": (503, "")])
    let replies = await Outbox.send(try signed(3), nodes: [server, desktop], transport: nodes.transport)
    #expect(replies == [.later, .later, .later])
    #expect(await nodes.asked == ["teoyujie.org", "10.0.0.2"], "after both are down, the next changes wait with no request")

    var journal = Journal()
    let id = journal.record(paper)
    let change = journal.outbox(now: now, key: "phone")[0]
    journal.apply(replies[0], to: change)
    #expect(journal[id]?.waiting == true, "the change stays in the outbox until a node acknowledges it")
}

@Test func withTheFallbackOffOnlyTheServerIsAsked() async throws {
    let off = Outbox.nodes(server: server, desktop: desktop.absoluteString, fallback: false)
    #expect(off == [server])
    let nodes = Nodes(["teoyujie.org": nil, "10.0.0.2": (201, "saved\n")])
    let replies = await Outbox.send(try signed(2), nodes: off, transport: nodes.transport)
    #expect(replies == [.later, .later], "each change stays in the outbox while the server is down")
    #expect(await nodes.asked == ["teoyujie.org"], "no change goes to the desktop")
}

@Test func withTheFallbackOnTheDesktopComesAfterTheServer() {
    #expect(Outbox.nodes(server: server, desktop: " \(desktop.absoluteString) ", fallback: true) == [server, desktop])
    for bad in ["", "10.0.0.2:8788", "ftp://10.0.0.2", "http://"] {
        #expect(Outbox.nodes(server: server, desktop: bad, fallback: true) == [server], "\(bad) is not a desktop")
    }
}

@Test func withNoDesktopOnlyTheServerIsAsked() async throws {
    let nodes = Nodes(["teoyujie.org": nil])
    let replies = await Outbox.send(try signed(2), nodes: [server], transport: nodes.transport)
    #expect(replies == [.later, .later])
    #expect(await nodes.asked == ["teoyujie.org"])
}

#if os(macOS)
/// The outbox against the built server/pond_save: 201, a retry (200), 409, 403 and a removal.
@Test func outboxAgainstTheServer() async throws {
    let program = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../server/pond_save").standardized
    #expect(FileManager.default.isExecutableFile(atPath: program.path()), "run server/build.sh first")
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: "entries"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appending(path: "keys"), withIntermediateDirectories: true)
    let key = P256.Signing.PrivateKey()
    try key.publicKey.derRepresentation.base64EncodedString().write(to: dir.appending(path: "keys/phone.pub"), atomically: true, encoding: .utf8)

    let path = dir.path()
    let server: Outbox.Transport = { request in
        let process = Process()
        process.executableURL = program
        process.environment = ["REQUEST_METHOD": "POST", "CONTENT_LENGTH": "\(request.httpBody!.count)",
                               "HTTP_SIGNATURE": request.value(forHTTPHeaderField: "Signature")!, "POND_DIR": path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(request.httpBody!)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let reply = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let status = Int(reply.firstMatch(of: /^Status: (\d+)/)!.1)!
        return (status, Data(reply.components(separatedBy: "\r\n\r\n").last!.utf8))
    }
    func flush(_ journal: inout Journal, signer: Signer = key) async throws -> [Reply] {
        let changes = journal.outbox(now: now, key: "phone")
        let replies = await Outbox.send(try changes.map { try SignedChange($0, signer: signer) },
                                        nodes: [URL(string: "https://teoyujie.org")!], transport: server)
        for (change, reply) in zip(changes, replies) { journal.apply(reply, to: change) }
        return replies
    }

    var journal = Journal()
    let id = journal.record(paper)
    #expect(try await flush(&journal, signer: P256.Signing.PrivateKey()) == [.later], "403: the key is not enrolled")
    #expect(try await flush(&journal) == [.accepted])
    #expect(journal[id]?.sentRev == 1)

    // A restored phone has an older journal: rev 1 is not sent, but the server has rev 1 of another body.
    var restored = journal
    restored.records[0].sentRev = 0
    restored.records[0].entry.title = "restored"
    #expect(try await flush(&restored) == [.conflict(saved: 1)])
    #expect(try await flush(&restored) == [.accepted])
    #expect(restored[id]?.rev == 2)

    restored.remove(id, at: now)
    #expect(try await flush(&restored) == [.accepted])
    #expect(restored[id] == nil)
    let saved = try String(contentsOf: dir.appending(path: "entries/\(id).json"), encoding: .utf8)
    #expect(saved.contains(#""op":"remove""#))
}
#endif
