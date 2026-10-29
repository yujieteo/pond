import Foundation
import Testing
@testable import PondKit

private let singapore: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
    return calendar
}()

/// 28 October 2026 + `days`, at 10:00 Singapore time.
private func day(_ days: Int) -> Date {
    singapore.date(from: DateComponents(year: 2026, month: 10, day: 28 + days, hour: 10))!
}

@Test func theStarterSetKeepsX1ToX8() {
    #expect(Experiment.starter.count == 5)
    #expect(Experiment.starter.flatMap(\.from).sorted() == ["X1", "X2", "X3", "X4", "X5", "X6", "X7", "X8"])
    #expect(Experiment.starter.allSatisfy { !$0.credit.isEmpty && !$0.steps.isEmpty })
    #expect(Experiment.starter("E1")?.title == "Feel it fully")
    #expect(Experiment.starter("E1")?.pickOne == true)
    #expect(Experiment.starter("E2")?.title == "Align with a stuck task")
}

@Test func anActiveExperimentIsThe4thChoiceForItsDays() {
    var journal = Journal()
    let loved = journal.record(Entry(date: "2026-10-27", title: "Brazil's top 10", domain: 2, mode: .home))
    journal.mark(loved, fun: .loved)
    var experiments = ExperimentLog()
    experiments.start("E2", on: "2026-10-28", days: 3)
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, experiments: experiments, now: day(0), calendar: singapore)

    let today = invite["2026-10-28"]!
    #expect(today.choices.count == 4)
    #expect(today.choices.last?.source == .experiment(id: "E2"))
    #expect(today.choices.last?.why == "Experiment · day 1 of 3")
    #expect(invite["2026-10-30"]?.choices.last?.why == "Experiment · day 3 of 3")
    #expect(invite["2026-10-31"]?.choices.contains { $0.source == .experiment(id: "E2") } == false)
}

@Test func startAndCloseChangeAnOfferedDay() {
    var journal = Journal()
    var invite = Invite()
    // After the notification time, today's choices stay; the experiment comes and goes as the last choice.
    let evening = singapore.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 21))!
    invite.offer(plan: plan, journal: &journal, now: evening, calendar: singapore)
    let before = invite["2026-10-28"]!.choices

    var experiments = ExperimentLog()
    experiments.start("E1", on: "2026-10-28")
    invite.offer(plan: plan, journal: &journal, experiments: experiments, now: evening, calendar: singapore)
    #expect(invite["2026-10-28"]!.choices == before + [experiments.choice(on: "2026-10-28")!])

    invite.pick(before.count, on: "2026-10-28")
    #expect(invite.done(on: "2026-10-28")?.kind == .note)
    experiments.count("2026-10-28")
    experiments.count("2026-10-28")
    #expect(experiments.active?.done == ["2026-10-28"])

    experiments.close(on: "2026-10-28", notice: "  ")
    #expect(experiments.active == nil)
    #expect(experiments.runs.last?.notice == nil, "an empty line is no notice")
    invite.offer(plan: plan, journal: &journal, experiments: experiments, now: evening, calendar: singapore)
    #expect(invite["2026-10-28"]!.choices == before)
    #expect(invite["2026-10-28"]!.pick == nil)
}

@Test func closeUndoAndPublishANotice() {
    var experiments = ExperimentLog()
    experiments.start("E5", on: "2026-10-28")
    experiments.close(on: "2026-11-04", notice: "Good things last longer when I stay.")
    experiments.reopen()
    #expect(experiments.active?.experiment == "E5")
    #expect(experiments.active?.notice == nil)

    experiments.close(on: "2026-11-04", notice: "Good things last longer when I stay.")
    let entry = ExperimentLog.noticeEntry(experiments.runs.last!, date: "2026-11-04")
    #expect(entry == Entry(date: "2026-11-04", title: "Good things last longer when I stay. (Let the good part land)",
                           link: URL(string: "https://www.artofaccomplishment.com/resources/experiments"), kind: .note))
}

@Test func theGridCountsEntriesInTheirCells() {
    var journal = Journal()
    journal.record(Entry(date: "2026-03-01", title: "A gig", domain: 2, mode: .live))
    journal.record(Entry(date: "2026-10-28", title: "Another gig", domain: 2, mode: .live))
    journal.record(Entry(date: "2025-12-31", title: "Last year", domain: 2, mode: .live))
    journal.record(Entry(date: "2026-10-28", title: "A note", kind: .note))
    let removed = journal.record(Entry(date: "2026-10-28", title: "Removed", domain: 5, mode: .home))
    journal.remove(removed, at: .now)

    let cells = Grid.entries(journal, year: "2026")
    #expect(cells.count == 1)
    #expect(cells[Cell(domain: 2, mode: .live)]?.map(\.entry.title) == ["A gig", "Another gig"])
    #expect(Grid.entries(journal, year: "2025").count == 1)
    #expect(Grid.years(journal, current: "2027") == ["2027", "2026", "2025"])
}

@Test func pickAnEmptyCellForToday() {
    var journal = Journal()
    var invite = Invite()
    invite.offer(plan: plan, journal: &journal, now: day(0), calendar: singapore)
    let choice = Menu.notVisited(plan.domains[11], .takePart, day: "2026-10-28")
    invite.pick(choice, on: "2026-10-28")
    let today = invite["2026-10-28"]!
    #expect(today.picked == choice)
    #expect(today.picked?.entry.title == "Hike")
    #expect(today.choices.filter { $0.source == .notVisited }.count == 1)
}
