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
                                        server: URL(string: "https://teoyujie.org")!, transport: server)
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
