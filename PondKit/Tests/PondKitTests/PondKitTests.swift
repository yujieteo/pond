import CryptoKit
import Foundation
import Testing
@testable import PondKit

/// media-plan.md is a copy of the real plan (firstmate data/waldenponding/media-plan.md, 2026-10-28).
let plan = Plan(markdown: try! String(contentsOf: Bundle.module.url(forResource: "Fixtures/media-plan", withExtension: "md")!, encoding: .utf8))

@Test func gridHasAll17DomainsWithFourModes() {
    #expect(plan.domains.map(\.number) == Array(1...17))
    #expect(plan.domains.allSatisfy { $0.cells.count == 4 })
    #expect(plan.domains[12].name == "Science and technology")
    #expect(plan.domains[1].cells[.live] == "concert, gig, getai, music festival")
}

@Test func eachDayHasItsSlots() {
    // 4 core slots on each workday, plus that day's theme slot.
    for day in Weekday.workdays { #expect(plan.slots(on: day).count == 5) }
    let wednesday = plan.slots(on: .wednesday).last!
    #expect(wednesday.text.hasPrefix("Text (1): one journal paper"))
    #expect(wednesday.made == "A summary of the paper in 3 sentences.")
    #expect(plan.slots(on: .friday).last!.domains == [16, 5])
    // The weekend lists, less the line that points to the monthly table.
    #expect(plan.slots(on: .saturday).count == 6)
    #expect(plan.slots(on: .sunday).count == 5)
    #expect(!plan.slots.contains { $0.text.hasPrefix("Monthly slot") })
    #expect(plan.slots(on: .saturday).last!.text.hasPrefix("Finish (45 minutes)"))
}

@Test func weekdayFromCalendar() {
    #expect(Weekday(calendarWeekday: 1) == .sunday)
    #expect(Weekday(calendarWeekday: 2) == .monday)
    #expect(Weekday(calendarWeekday: 7) == .saturday)
}

@Test func hostGuesses() {
    #expect(HostDomain.guess(for: URL(string: "https://m.youtube.com/watch?v=x")!) == .init(domain: 5, mode: .home))
    #expect(HostDomain.guess(for: URL(string: "https://www.eventbrite.sg/e/1")!) == .init(domain: nil, mode: .live))
    #expect(HostDomain.guess(for: URL(string: "https://arxiv.org/abs/2401.1")!)?.domain == 13)
    #expect(HostDomain.guess(for: URL(string: "https://example.org/")!) == nil)
}

@Test func signedChangeVerifies() throws {
    let key = P256.Signing.PrivateKey()
    let entry = Entry(date: "2026-10-28", title: "1987 - IEEE Standard on Piezoelectricity",
                      link: URL(string: "https://example.org/std")!, domain: 15, mode: .home)
    let signed = try SignedChange(.put(entry, id: "e1", rev: 1, key: "phone"), signer: key)
    let text = String(decoding: signed.body, as: UTF8.self)
    #expect(text == #"{"entry":{"date":"2026-10-28","domain":15,"kind":"media","link":"https://example.org/std","mode":"home","title":"1987 - IEEE Standard on Piezoelectricity"},"id":"e1","key":"phone","op":"put","rev":1,"v":1}"#)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: signed.signature)!)
    #expect(key.publicKey.isValidSignature(signature, for: signed.body))

    let request = signed.request(server: URL(string: "https://teoyujie.org")!)
    #expect(request.url?.absoluteString == "https://teoyujie.org/pond/entry")
    #expect(request.value(forHTTPHeaderField: "Signature") == signed.signature)
    #expect(request.httpBody == signed.body)
}

@Test func removeHasNoEntry() throws {
    let signed = try SignedChange(.remove(id: "e1", rev: 2, key: "phone"), signer: P256.Signing.PrivateKey())
    #expect(String(decoding: signed.body, as: UTF8.self) == #"{"id":"e1","key":"phone","op":"remove","rev":2,"v":1}"#)
}

#if os(macOS)
/// The server's libcrypto accepts what CryptoKit signs. Run server/build.sh first.
@Test func serverAcceptsCryptoKitSignature() throws {
    let program = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../server/pond_save").standardized
    #expect(FileManager.default.isExecutableFile(atPath: program.path()), "run server/build.sh first")
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: "entries"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appending(path: "keys"), withIntermediateDirectories: true)
    let key = P256.Signing.PrivateKey()
    try key.publicKey.derRepresentation.base64EncodedString().write(to: dir.appending(path: "keys/phone.pub"), atomically: true, encoding: .utf8)

    func post(_ signed: SignedChange) throws -> String {
        let process = Process()
        process.executableURL = program
        process.environment = ["REQUEST_METHOD": "POST", "CONTENT_LENGTH": "\(signed.body.count)",
                               "HTTP_SIGNATURE": signed.signature, "POND_DIR": dir.path()]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(signed.body)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    let entry = Entry(date: "2026-10-28", title: "an album", domain: 2, mode: .home)
    #expect(try post(SignedChange(.put(entry, id: "e1", rev: 1, key: "phone"), signer: key)).hasPrefix("Status: 201"))
    #expect(try post(SignedChange(.put(entry, id: "e1", rev: 1, key: "phone"), signer: P256.Signing.PrivateKey())).hasPrefix("Status: 403"))
    let paper = Entry(date: "2026-10-28", title: "a paper", link: URL(string: "https://arxiv.org/abs/2610.00001")!,
                      made: "a note", domain: 15, mode: .home, kind: .note, slot: "morning", interest: "biology")
    #expect(try post(SignedChange(.put(paper, id: "e2", rev: 1, key: "phone"), signer: key)).hasPrefix("Status: 201"))
}
#endif

@Test func onePaperTakesTheInterestReadLeastLately() {
    let day: TimeInterval = 86_400
    let biology = Interest(name: "biology", sources: [.arxiv("q-bio.PE")], lastRead: Date(timeIntervalSince1970: 10 * day))
    let aero = Interest(name: "aerospace structures", sources: [.feed(URL(string: "https://example.org/aiaa.rss")!)],
                        classics: [Paper(title: "Wagner 1929: tension field beams", link: URL(string: "https://example.org/wagner")!)],
                        lastRead: Date(timeIntervalSince1970: 2 * day))
    let older = Paper(title: "older", link: URL(string: "https://example.org/1")!, published: Date(timeIntervalSince1970: 1 * day))
    let newer = Paper(title: "newer", link: URL(string: "https://example.org/2")!, published: Date(timeIntervalSince1970: 3 * day))
    let bio = Paper(title: "bio", link: URL(string: "https://example.org/3")!)
    let papers = ["aerospace structures": [older, newer], "biology": [bio]]

    let pick = OnePaper.pick(interests: [biology, aero], papers: papers, read: [], today: .monday, oldDays: [.wednesday])
    #expect(pick?.interest.name == "aerospace structures")
    #expect(pick?.paper == newer)

    let next = OnePaper.pick(interests: [biology, aero], papers: papers, read: [newer.id], today: .monday, oldDays: [.wednesday])
    #expect(next?.paper == older)

    // With all of its papers read, the next interest gives one.
    let moved = OnePaper.pick(interests: [biology, aero], papers: papers, read: [newer.id, older.id], today: .monday, oldDays: [.wednesday])
    #expect(moved?.interest.name == "biology")

    // On an old day, a classic.
    let old = OnePaper.pick(interests: [biology, aero], papers: papers, read: [], today: .wednesday, oldDays: [.wednesday])
    #expect(old?.paper.title == "Wagner 1929: tension field beams")

    // An interest never read comes first.
    let new = Interest(name: "optics", sources: [.arxiv("physics.optics")])
    let first = OnePaper.pick(interests: [biology, aero, new], papers: papers.merging(["optics": [bio]]) { a, _ in a },
                              read: [], today: .monday, oldDays: [])
    #expect(first?.interest.name == "optics")
}

@Test func arxivCategoryIsAnAtomFeed() {
    #expect(Interest.Source.arxiv("physics.optics").url.absoluteString == "https://rss.arxiv.org/atom/physics.optics")
}

@Test func feedParserReadsRSSAndAtom() {
    let rss = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>Journal</title><link>https://example.org</link>
    <item><title>A paper</title><link>https://example.org/a</link><pubDate>Tue, 27 Oct 2026 08:00:00 +0000</pubDate></item>
    <item><title>No link</title></item>
    </channel></rss>
    """
    let atom = """
    <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>arXiv</title><link href="https://arxiv.org"/>
    <entry><title>Light in a fibre</title><link rel="alternate" href="https://arxiv.org/abs/2610.1"/><link rel="related" href="https://arxiv.org/pdf/2610.1"/>
    <published>2026-10-27T00:00:00Z</published></entry>
    </feed>
    """
    let fromRSS = FeedParser.parse(Data(rss.utf8))
    #expect(fromRSS.map(\.title) == ["A paper"])
    #expect(fromRSS[0].published == Date(timeIntervalSince1970: 1_793_088_000))
    let fromAtom = FeedParser.parse(Data(atom.utf8))
    #expect(fromAtom.map(\.link.absoluteString) == ["https://arxiv.org/abs/2610.1"])
    #expect(fromAtom[0].published == Date(timeIntervalSince1970: 1_793_059_200))
}
