import Foundation
import Testing
@testable import PondKit

private let singapore: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
}()

/// Wednesday 28 October 2026 at `hour`:`minute`, Singapore time.
private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
    singapore.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
}

private func lovedChart() -> (Journal, String) {
    var journal = Journal()
    let id = journal.record(Entry(date: "2026-10-27", title: "Brazil's top 10", domain: 2, mode: .home))
    journal.mark(id, fun: .loved)
    return (journal, id)
}

@Test func offerMakesTheChoicesOfTodayAndTheNext13Days() {
    var (journal, _) = lovedChart()
    let menu = Menu.choices(plan: plan, journal: journal, date: wednesday(10), calendar: singapore)
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    #expect(invite.days.count == 14)
    #expect(invite.days.first?.date == "2026-10-28")
    #expect(invite.days.last?.date == "2026-11-10")
    #expect(invite.days.allSatisfy { !$0.choices.isEmpty && $0.choices.count <= Invite.maxChoices })
    #expect(invite.days.allSatisfy { day in day.choices.allSatisfy { $0.entry.date == day.date } })
    #expect(invite["2026-10-28"]?.choices == menu)
}

@Test func anEnjoyedEntryComesBackAtMostOnceIn14ScheduledDays() {
    var (journal, id) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    let days = invite.days.filter { $0.choices.contains { $0.source == .enjoyed(id: id) } }.map(\.date)
    #expect(days == ["2026-10-28"])
    #expect(journal[id]?.offered == nil, "a day not yet offered marks nothing")

    // The next day, today's choice is earlier and not offered again: 14 days later is the first day again.
    let thursday = singapore.date(byAdding: .day, value: 1, to: wednesday(10))!
    invite.offer(plan: plan, journal: &journal, now: thursday, calendar: singapore)
    #expect(invite.days.first?.date == "2026-10-29", "an earlier day goes, with no mark")
    #expect(invite.days.filter { $0.choices.contains { $0.source == .enjoyed(id: id) } }.map(\.date) == ["2026-11-11"])
}

@Test func aPastMarkSurvivesEachOfferOfTheNextDay() {
    var (journal, id) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)

    let thursday = singapore.date(byAdding: .day, value: 1, to: wednesday(10))!
    for minutes in [0, 5] {
        invite.offer(plan: plan, journal: &journal, now: thursday + Double(minutes * 60), calendar: singapore)
        #expect(journal[id]?.offered == "2026-10-28")
        #expect(invite.days.filter { $0.choices.contains { $0.source == .enjoyed(id: id) } }.map(\.date) == ["2026-11-11"])
    }
}

@Test func aDayNotYetOfferedGetsNewChoices() {
    var (journal, id) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    #expect(invite["2026-10-28"]?.choices.count == 3)

    // Before the invite time, a change makes today's choices again: the removed entry is not offered.
    journal.remove(id, at: wednesday(10))
    invite.offer(plan: plan, journal: &journal, now: wednesday(11), calendar: singapore)
    #expect(invite["2026-10-28"]?.choices.count == 2)
    #expect(journal[id]?.offered == nil, "a mark of a day that is made again goes")
}

@Test func anOfferedDayKeepsItsChoices() {
    var (journal, id) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    let offered = invite["2026-10-28"]

    // After 19:30, the notification has the choices, so they stay.
    journal.remove(id, at: wednesday(19, 31))
    invite.offer(plan: plan, journal: &journal, now: wednesday(19, 31), calendar: singapore)
    #expect(invite["2026-10-28"] == offered)
    #expect(invite["2026-10-29"]?.choices.count == 2)
}

@Test func aPickKeepsTheChoicesOfItsDay() {
    var (journal, id) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    invite.pick(1, on: "2026-10-28")
    journal.remove(id, at: wednesday(11))
    invite.offer(plan: plan, journal: &journal, now: wednesday(11), calendar: singapore)
    #expect(invite["2026-10-28"]?.choices.count == 3)
    #expect(invite["2026-10-28"]?.picked?.source == .enjoyed(id: id))
}

@Test func pickUnpickAndDone() {
    var (journal, _) = lovedChart()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: wednesday(10), calendar: singapore)
    let day = "2026-10-28"

    #expect(invite.done(on: day) == nil, "no pick, no entry")
    invite.pick(7, on: day)
    #expect(invite[day]?.pick == nil, "no such choice")
    invite.pick(0, on: day)
    invite.pick(2, on: day)
    #expect(invite[day]?.pick == 2, "one pick at most")
    invite.unpick(on: day)
    #expect(invite[day]?.pick == nil)

    invite.pick(0, on: day)
    let entry = invite.done(on: day)
    #expect(entry == invite[day]?.choices[0].entry)
    #expect(entry?.date == day)
    #expect(invite[day]?.done == true)
    #expect(invite.done(on: day) == nil, "a second Done records nothing")
    #expect(invite.done(on: "2026-10-01") == nil, "an earlier day records nothing")

    invite.pick(1, on: day)
    #expect(invite[day]?.done == false, "a new pick can be done again")
}

@Test func theInviteTimeIsTheTimeOfEachNotification() throws {
    var invite = Invite()
    #expect(invite.time(of: "2026-10-28", calendar: singapore) == wednesday(19, 30))
    invite.setTime(hour: 7, minute: 5)
    #expect(invite.time(of: "2026-10-28", calendar: singapore) == wednesday(7, 5))
    let data = try JSONEncoder().encode(invite)
    #expect(try JSONDecoder().decode(Invite.self, from: data) == invite)
}
