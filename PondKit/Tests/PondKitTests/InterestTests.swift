import Foundation
import Testing
@testable import PondKit

private let singapore: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
}()

/// 28 October 2026 is a Wednesday: the fixture plan's "one journal paper" slot.
private func october(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    singapore.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func paper(_ name: String) -> Paper {
    Paper(title: name, link: URL(string: "https://arxiv.org/abs/\(name)")!, published: october(27, 8))
}

private var interests: Interests {
    var interests = Interests(topics: [
        Interest(name: "Math", sources: [.arxiv("math.HO")]),
        Interest(name: "Biology", sources: [.arxiv("q-bio.PE")],
                 classics: [Paper(title: "Hopfield 1982", link: URL(string: "https://www.pnas.org/doi/10.1073/pnas.79.8.2554")!)]),
    ])
    interests.papers = ["Math": [paper("m1"), paper("m2")], "Biology": [paper("b1")]]
    return interests
}

@Test func onePaperSlotOffersAPaperFromAnInterest() {
    let choices = Menu.choices(plan: plan, journal: Journal(), date: october(28, 10), calendar: singapore, interests: interests)
    let slot = choices.first { $0.source == .slot }!
    #expect(slot.why == "One paper · Math · arXiv")
    #expect(slot.entry.title == "m1")
    #expect(slot.entry.interest == "Math")
    #expect(slot.entry.link?.absoluteString == "https://arxiv.org/abs/m1")
    #expect(slot.entry.slot?.hasPrefix("Text (1): one journal paper") == true)

    // With no paper to offer, the slot is the slot.
    let plain = Menu.choices(plan: plan, journal: Journal(), date: october(28, 10), calendar: singapore)
    #expect(plain.first?.why == "Today's slot · Text")
}

@Test func aReadPaperMovesOnePaperToTheInterestReadLeastLately() {
    var journal = Journal()
    journal.record(Entry(date: "2026-10-21", title: "m1", link: URL(string: "https://arxiv.org/abs/m1"), interest: "Math"))
    let slot = Menu.choices(plan: plan, journal: journal, date: october(28, 10), calendar: singapore, interests: interests)[0]
    #expect(slot.entry.interest == "Biology")
    #expect(slot.entry.title == "b1")
}

@Test func anOldDayOffersAClassic() {
    var old = interests
    old.oldDays = [.wednesday]
    // Math has no classic, so Biology gives one.
    let slot = Menu.choices(plan: plan, journal: Journal(), date: october(28, 10), calendar: singapore, interests: old)[0]
    #expect(slot.entry.title == "Hopfield 1982")
    #expect(slot.why == "One paper · Biology · classic")
}

@Test func theNextPaperDaysOfTheInviteOfferOtherPapers() {
    var paperDays = plan
    let index = paperDays.slots.firstIndex { $0.isOnePaper }!
    paperDays.setDays(index, Set(Weekday.allCases))
    var journal = Journal()
    var invite = Invite()
    invite.offer(plan: paperDays, journal: &journal, interests: interests, now: october(28, 10), calendar: singapore)
    let titles = invite.days.compactMap { day in day.choices.first { $0.entry.interest != nil }?.entry.title }
    #expect(titles.prefix(3) == ["m1", "b1", "m2"], "each day the interest read least lately, and no paper twice")
}

@Test func slotIsOnePaper() {
    #expect(plan.slots.filter(\.isOnePaper).map(\.text).count == 1)
    #expect(Slot(text: "Text (1): One paper, from an interest", made: nil, domains: [1], days: .everyDay, part: .added, line: 0).isOnePaper)
}

@Test func sourceFromTheField() {
    #expect(Interests.source("math.HO") == .arxiv("math.HO"))
    #expect(Interests.source(" q-bio ") == .arxiv("q-bio"))
    #expect(Interests.source("https://www.nature.com/nature.rss") == .feed(URL(string: "https://www.nature.com/nature.rss")!))
    #expect(Interests.source("not a feed") == nil)
}

// MARK: live events (R15)

private let openMic = Event(id: "mic", title: "Open mic at The Projector", start: october(28, 20), place: "The Projector, Singapore",
                            cost: "free", link: URL(string: "https://theprojector.sg/events/open-mic"), domain: 6)

@Test func anEventIsTheLiveChoiceOfItsDay() {
    let choices = Menu.choices(plan: plan, journal: Journal(), date: october(28, 10), calendar: singapore, events: [openMic])
    let live = choices.last!
    #expect(live.source == .event(id: "mic"))
    #expect(live.why == "Live · 20:00 · free")
    #expect(live.entry == Entry(date: "2026-10-28", title: "Open mic at The Projector",
                                link: URL(string: "https://theprojector.sg/events/open-mic"), domain: 6, mode: .live))
    #expect(!choices.contains { $0.source == .notVisited })
    // The next day has no event: the "not visited" choice comes back.
    let next = Menu.choices(plan: plan, journal: Journal(), date: october(29, 10), calendar: singapore, events: [openMic])
    #expect(next.contains { $0.source == .notVisited })
}

@Test func anEventSavedAfterTheInviteTimeIsStillTheLiveChoiceOfToday() {
    var journal = Journal()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: october(28, 19, 45), calendar: singapore)
    #expect(invite["2026-10-28"]?.choices.contains { $0.source == .notVisited } == true)
    invite.offer(plan: plan, journal: &journal, events: [openMic], now: october(28, 19, 50), calendar: singapore)
    let today = invite["2026-10-28"]!
    #expect(today.choices.contains { $0.source == .event(id: "mic") })
    #expect(!today.choices.contains { $0.source == .notVisited })

    // A picked event stays when it is removed; an event that is not the pick goes.
    let index = today.choices.firstIndex { $0.source == .event(id: "mic") }!
    var picked = invite
    picked.pick(index, on: "2026-10-28")
    picked.offer(plan: plan, journal: &journal, now: october(28, 19, 55), calendar: singapore)
    #expect(picked["2026-10-28"]?.picked?.source == .event(id: "mic"))
    invite.offer(plan: plan, journal: &journal, now: october(28, 19, 55), calendar: singapore)
    #expect(invite["2026-10-28"]?.choices.contains { $0.source == .event(id: "mic") } == false)
}

@Test func anEventSavedAfterADoneComesAfterThePick() {
    var journal = Journal()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: october(28, 19, 45), calendar: singapore)
    let notVisited = invite["2026-10-28"]!.choices.firstIndex { $0.source == .notVisited }!
    invite.pick(notVisited, on: "2026-10-28")
    #expect(invite.done(on: "2026-10-28") != nil)
    invite.offer(plan: plan, journal: &journal, events: [openMic], now: october(28, 19, 50), calendar: singapore)
    let today = invite["2026-10-28"]!
    #expect(today.choices[notVisited].source == .notVisited)
    #expect(today.choices.last?.source == .event(id: "mic"))
    #expect(today.done)
}

@Test func goOpensTheDirections() {
    #expect(openMic.directions.absoluteString == "https://maps.apple.com/?daddr=The%20Projector,%20Singapore")
}

// MARK: daily reading (R13)

@Test func everyDayItemsAreTheWeekdayCore() {
    let core = plan.slots.filter { $0.part == .core }
    #expect(core.map { Menu.dailyName($0.text) }
        == ["News and blogs from one RSS reader", "Textbook", "Fiction or history", "Ask one person one real question"])
    var edited = plan
    edited.addSlot("Text (1): poetry, one poem", days: Set(Weekday.allCases), part: .core)
    let added = edited.slots.filter { $0.part == .core }
    #expect(added.count == core.count + 1)
    #expect(added.last?.text == "Text (1): poetry, one poem")
    #expect(added.last?.weekdays == Set(Weekday.allCases))
    #expect(edited.markdown.contains("- [ ] People (17): ask one person one real question, and write one line about the answer. This is a conversation, not media time.\n- [ ] Text (1): poetry, one poem (days: every day)\n"))

    // A plan with no core gets the heading with its first item.
    var bare = Plan(markdown: "# Plan\n")
    bare.addSlot("RSS, 10 min", days: Weekday.workdays, part: .core)
    #expect(bare.slots.map(\.text) == ["RSS, 10 min"])
    #expect(bare.slots.first?.part == .core)
}
