import Foundation
import Testing
@testable import PondKit

@Test func setDaysWritesAMarkerAndTheParserReadsIt() {
    var edited = plan
    let index = edited.slots.firstIndex { $0.text.hasPrefix("Text (1): one journal paper") }!
    edited.setDays(index, [.monday, .wednesday, .friday])
    #expect(edited.slots[index].weekdays == [.monday, .wednesday, .friday])
    #expect(edited.markdown.contains("Read the abstract, the figures and the conclusion first. (days: Mon Wed Fri) | A summary"))
    #expect(edited.slots[index].text == plan.slots[index].text, "the marker is not in the text")
    #expect(Plan(markdown: edited.markdown) == edited)

    // The days of its row again: the marker goes, and the file is the same as before.
    edited.setDays(index, [.wednesday])
    #expect(edited.markdown == plan.markdown)
}

@Test func aListSlotOnMoreDays() {
    var edited = plan
    let index = edited.slots.firstIndex { $0.text.hasPrefix("Games (7): puzzles") }!
    edited.setDays(index, Set(Weekday.allCases))
    #expect(edited.markdown.contains("- [ ] Games (7): puzzles (crossword, logic puzzle or chess problem), 20 minutes. (days: every day)"))
    #expect(edited.slots(on: .tuesday).contains { $0.text.hasPrefix("Games (7)") })
    edited.setDays(index, [])
    #expect(edited.markdown.contains("20 minutes. (days: none)"))
    #expect(!Weekday.allCases.contains { day in edited.slots(on: day).contains { $0.text.hasPrefix("Games (7)") } })
}

@Test func editAddAndRemoveASlot() {
    var edited = plan
    let index = edited.slots.firstIndex { $0.text.hasPrefix("Text (1): one poem") }!
    edited.editSlot(index, text: "Text (1): two poems,\nread aloud.")
    #expect(edited.slots[index].text == "Text (1): two poems, read aloud.")
    #expect(edited.slots[index].days == .on([.saturday]))

    edited.addSlot("Text (1): one paper, from an interest", days: [.monday, .friday])
    edited.addSlot("Nature (12): a walk in a park", days: [.sunday])
    let added = edited.slots.filter { $0.part == .added }
    #expect(added.map(\.text) == ["Text (1): one paper, from an interest", "Nature (12): a walk in a park"])
    #expect(added.first?.domains == [1])
    #expect(edited.markdown.contains("- [ ] Monthly slot: see the table below.\n\n**Added in the app**\n\n- [ ] Text (1): one paper, from an interest (days: Mon Fri)\n- [ ] Nature (12): a walk in a park (days: Sun)\n\n**Monthly slot"))
    #expect(edited.slots(on: .friday).contains { $0.text == "Text (1): one paper, from an interest" })
    #expect(edited.domains == plan.domains)

    edited.removeSlot(edited.slots.firstIndex { $0.text == "Nature (12): a walk in a park" }!)
    edited.removeSlot(edited.slots.firstIndex { $0.text == "Text (1): one paper, from an interest" }!)
    #expect(!edited.slots.contains { $0.part == .added })
    #expect(edited.slots.count == plan.slots.count)

    edited.removeSlot(edited.slots.firstIndex { $0.text.hasPrefix("Finish (45 minutes)") }!)
    #expect(edited.markdown.contains("- [ ] Text (1): two poems, read aloud.\n- [ ] Monthly slot: see the table below."))
}

@Test func aTableCellKeepsNoBar() {
    var edited = plan
    let index = edited.slots.firstIndex { $0.part == .theme }!
    edited.editSlot(index, text: "Text (1): essays | newsletters")
    #expect(edited.slots[index].text == "Text (1): essays / newsletters")
    #expect(edited.slots[index].made == plan.slots[index].made)
}

@Test func theMenuKeepsTheCoreOutAlsoWhenASlotIsOnEachWorkday() {
    var edited = plan
    let index = edited.slots.firstIndex { $0.part == .theme }!
    edited.setDays(index, Weekday.workdays)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10))!
    let choices = Menu.choices(plan: edited, journal: Journal(), date: tuesday, calendar: calendar)
    let slot = choices.first { $0.source == .slot }!
    #expect(!plan.slots.filter { $0.part == .core }.contains { $0.text == slot.entry.slot })
}

@Test func planRepoLoadsAndCommits() async throws {
    let api = URL(string: "https://api.example.org")!
    let text = "# Media plan\n\nnon-ASCII: café\n"
    let content = Array(Data(text.utf8).base64EncodedString()).chunked(60).joined(separator: "\n")
    let loaded = try await PlanRepo.load(api: api, token: nil) { request in
        #expect(request.url?.absoluteString == "https://api.example.org/repos/yujieteo/site/contents/media-plan.md?ref=main")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (200, Data(#"{"sha":"abc","content":"\#(content.replacingOccurrences(of: "\n", with: "\\n"))","encoding":"base64"}"#.utf8))
    }
    #expect(loaded == PlanRepo.File(text: text, sha: "abc"))

    let saved = await PlanRepo.commit(text, sha: "abc", api: api, token: "t0k") { request in
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
        #expect(body["sha"] == "abc")
        #expect(body["branch"] == "main")
        #expect(Data(base64Encoded: body["content"]!) == Data(text.utf8))
        return (200, Data(#"{"content":{"sha":"def"},"commit":{}}"#.utf8))
    }
    #expect(saved == .saved(sha: "def"))
    #expect(await PlanRepo.commit(text, sha: "old", api: api, token: "t") { _ in (409, Data()) } == .conflict)
    #expect(await PlanRepo.commit(text, sha: "abc", api: api, token: "bad") { _ in (401, Data()) } == .refused(status: 401))
    #expect(await PlanRepo.commit(text, sha: "abc", api: api, token: "t") { _ in throw URLError(.notConnectedToInternet) } == .later)
}

private extension Array where Element == Character {
    func chunked(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { String(self[$0..<Swift.min($0 + size, count)]) }
    }
}
