import Foundation
import Observation
import PondKit
import WidgetKit

/// The state of the app: the journal on the phone, the plan, the invite, the experiments, the key and the sends.
/// One store serves the app, the notification and the widgets' buttons.
@Observable @MainActor
final class Store {
    static let shared = Store()

    private(set) var journal: Journal
    private(set) var plan: Plan
    private(set) var invite: Invite
    /// The runs of experiments. They stay on the phone (R10).
    private(set) var experiments: ExperimentLog
    /// The interests of "One paper" and their fetched papers. They stay on the phone.
    private(set) var interests: Interests
    /// The live events saved for their day (R15). They stay on the phone.
    private(set) var events: [Event]
    private(set) var key: Result<DeviceKey, Error>?

    static let everyDaySlot = "Every day"

    /// The save service. A launch argument `-server http://127.0.0.1:8787` changes it for a local test server.
    let server = URL(string: UserDefaults.standard.string(forKey: "server") ?? "https://teoyujie.org")!

    private let file = URL.applicationSupportDirectory.appending(path: "journal.json")
    private let experimentsFile = URL.applicationSupportDirectory.appending(path: "experiments.json")
    private let interestsFile = URL.applicationSupportDirectory.appending(path: "interests.json")
    private let eventsFile = URL.applicationSupportDirectory.appending(path: "events.json")
    private var sending = false
    private var wake: Task<Void, Never>?
    private var scheduling: Task<Void, Never>?

    init() {
        journal = (try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))) ?? Journal()
        experiments = (try? JSONDecoder().decode(ExperimentLog.self, from: Data(contentsOf: experimentsFile))) ?? ExperimentLog()
        interests = (try? JSONDecoder().decode(Interests.self, from: Data(contentsOf: interestsFile))) ?? Interests.starter
        // An event of an earlier day goes, with no mark.
        let today = Menu.day(.now)
        events = ((try? JSONDecoder().decode([Event].self, from: Data(contentsOf: eventsFile))) ?? [])
            .filter { Menu.day($0.start) >= today }
        plan = PlanSync.shared.plan
        invite = SharedInvite.load()
        offer()
    }

    var today: String { Menu.day(.now) }

    /// Today's choices and pick: the same in the app, the notification and the widgets.
    var inviteToday: InviteDay? { invite[today] }

    /// The entries of today on the screen, newest first.
    var doneToday: [Record] {
        journal.records.filter { !$0.removed && $0.entry.date == today }.reversed()
    }

    /// The "Every day" items of today (R13): the weekday core of the plan on today's weekday, by their short names.
    var everyDay: [String] {
        let weekday = Weekday(calendarWeekday: Calendar.current.component(.weekday, from: .now))
        return plan.slots(on: weekday).filter { $0.part == .core }.map { Menu.dailyName($0.text) }
    }

    func everyDayRecord(_ name: String) -> Record? {
        doneToday.first { $0.entry.slot == Store.everyDaySlot && $0.entry.title == name }
    }

    func domainName(_ number: Int?) -> String? {
        plan.domains.first { $0.number == number }?.name
    }

    func loadKey() {
        if case .success = key { return }
        key = Result(catching: { try DeviceKey.load() })
    }

    /// Makes the choices of each day not yet offered, and schedules their notifications (docs/concepts.md, sync 1).
    /// It schedules the notifications also with no change, because the app can open after a reinstall or a restore.
    func offer() {
        offer(before: invite)
    }

    func setInviteTime(_ time: Date) {
        let before = invite
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        invite.setTime(hour: parts.hour ?? 19, minute: parts.minute ?? 30)
        offer(before: before)
    }

    /// A change of the plan in the plan editor makes the choices of the days not yet offered again (sync 1).
    func setPlan(_ plan: Plan) {
        self.plan = plan
        offer()
    }

    private func offer(before: Invite) {
        let journal = journal
        invite.offer(plan: plan, journal: &self.journal, experiments: experiments, interests: interests, events: events, now: .now)
        if self.journal != journal { save() }
        if !inviteChanged(before) { schedule() }
        LiveEvent.update(invite[today], events: events)
    }

    /// A pick changes the notification in place and the widgets (sync 2 and 14).
    func pick(_ index: Int, on day: String) {
        let before = invite
        invite.pick(index, on: day)
        inviteChanged(before)
        LiveEvent.update(invite[day], events: events)
    }

    /// "Pick for today" on an empty cell of the grid.
    func pick(_ cell: Cell) {
        guard let domain = plan.domains.first(where: { $0.number == cell.domain }) else { return }
        let before = invite
        invite.pick(Menu.notVisited(domain, cell.mode, day: today), on: today)
        inviteChanged(before)
    }

    func unpick(on day: String) {
        let before = invite
        invite.unpick(on: day)
        inviteChanged(before)
    }

    /// "Done" in the app, the notification or a widget: records the pick, then signs and sends it (sync 3).
    /// With no network, the entry waits in the outbox. "Done" on the experiment counts a day of its run and records nothing (sync 7).
    @discardableResult
    func done(on day: String) -> String? {
        let before = invite
        let source = invite[day]?.picked?.source
        guard let entry = invite.done(on: day) else { return nil }
        if case .experiment = source {
            experiments.count(day)
            saveExperiments()
            inviteChanged(before)
            return nil
        }
        let id = record(entry)
        inviteChanged(before)
        LiveEvent.update(invite[day], events: events)
        return id
    }

    // MARK: interests (R14)

    func setInterests(_ interests: Interests) {
        self.interests = interests
        Store.write(interests, to: interestsFile)
        offer()
    }

    /// Reads the feeds of each interest, at most once in 6 hours. A fetch that fails or gives no papers keeps the earlier papers.
    func fetchPapers() async {
        guard (interests.fetched.map { $0 < .now - 6 * 3600 } ?? true) else { return }
        var papers = interests.papers
        for topic in interests.topics {
            var items: [Paper] = []
            for source in topic.sources {
                if let (data, response) = try? await URLSession.shared.data(from: source.url),
                   let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                    items += FeedParser.parse(data)
                }
            }
            if topic.sources.isEmpty || !items.isEmpty { papers[topic.name] = Array(items.prefix(100)) }
        }
        var next = interests
        next.papers = papers.filter { name, _ in interests.topics.contains { $0.name == name } }
        next.fetched = .now
        setInterests(next)
    }

    // MARK: live events (R15)

    func saveEvent(_ event: Event) {
        events.removeAll { $0.id == event.id }
        events.append(event)
        events.sort { $0.start < $1.start }
        eventsChanged()
    }

    /// The event goes at once. It is only on the phone, so "Undo" puts it back with no send.
    func removeEvent(_ id: String) {
        events.removeAll { $0.id == id }
        eventsChanged()
    }

    /// "Done" on the live event of `day`, from Today or the Live Activity: the same as "Done" on its pick.
    @discardableResult
    func doneEvent(_ id: String, on day: String) -> String? {
        guard let index = invite[day]?.choices.firstIndex(where: { $0.source == .event(id: id) }) else { return nil }
        if invite[day]?.pick != index { pick(index, on: day) }
        return done(on: day)
    }

    /// The saved event of a live choice.
    func event(of choice: Choice) -> Event? {
        guard case .event(let id) = choice.source else { return nil }
        return events.first { $0.id == id }
    }

    private func eventsChanged() {
        Store.write(events, to: eventsFile)
        offer()
    }

    private static func write(_ value: some Encodable, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: experiments

    func startExperiment(_ id: String) {
        experiments.start(id, on: today)
        experimentsChanged()
    }

    /// Closes the active run with its notice. A published notice becomes an entry after `undo` seconds, if no "Undo" came (sync 8).
    func closeExperiment(notice: String?, publish: Bool, undo: TimeInterval) {
        experiments.close(on: today, notice: notice)
        experimentsChanged()
        guard publish, let run = experiments.runs.last, run.notice != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(undo))
            guard let last = experiments.runs.indices.last, experiments.runs[last] == run,
                  let entry = ExperimentLog.noticeEntry(run, date: today) else { return }
            experiments.runs[last].published = record(entry)
            saveExperiments()
        }
    }

    func reopenExperiment() {
        experiments.reopen()
        experimentsChanged()
    }

    private func experimentsChanged() {
        saveExperiments()
        offer()
    }

    private func saveExperiments() {
        try? FileManager.default.createDirectory(at: experimentsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(experiments).write(to: experimentsFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The work that a button of the notification or a widget waits for before the app goes back to the background.
    func finish() async {
        await flush()
        await scheduling?.value
    }

    /// Saves the invite and updates the notifications and the widgets, if the invite changed.
    @discardableResult
    private func inviteChanged(_ before: Invite) -> Bool {
        guard invite != before else { return false }
        SharedInvite.save(invite)
        WidgetCenter.shared.reloadAllTimelines()
        schedule()
        return true
    }

    private func schedule() {
        let invite = invite
        scheduling = Task { [scheduling] in
            await scheduling?.value
            await InviteNotifications.schedule(invite)
        }
    }

    @discardableResult
    func record(_ entry: Entry) -> String {
        let id = journal.record(entry)
        changed()
        return id
    }

    func edit(_ id: String, entry: Entry) {
        journal.edit(id, entry: entry)
        changed()
    }

    func mark(_ id: String, fun: Fun?) {
        journal.mark(id, fun: fun)
        save()
    }

    /// The entry goes from the screen at once; the phone sends the removal after `undo` seconds.
    func remove(_ id: String, undo: TimeInterval) {
        journal.remove(id, at: .now + undo)
        changed()
    }

    func restore(_ id: String) {
        journal.restore(id)
        changed()
    }

    func toggleEveryDay(_ name: String) {
        if let record = everyDayRecord(name) {
            remove(record.id, undo: 0)
        } else {
            let slot = plan.slots.first { $0.part == .core && Menu.dailyName($0.text) == name }
            record(Entry(date: today, title: name, domain: slot?.domains.first ?? 1, mode: .home, slot: Store.everyDaySlot))
        }
    }

    private func changed() {
        save()
        offer()
        Task { await flush() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(journal).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Sends each waiting change, signed. A failed send stays in the journal and goes again later:
    /// at the next change, when the app comes back, or after a minute while the app is open.
    func flush() async {
        guard !sending else { return }
        loadKey()
        guard case .success(let key) = key else { return }
        sending = true
        defer { sending = false }
        for _ in 0..<3 {
            let changes = journal.outbox(now: .now, key: key.name)
            save()
            guard !changes.isEmpty else { break }
            let signed = changes.compactMap { try? SignedChange($0, signer: key.signer) }
            guard signed.count == changes.count else { break }
            let replies = await Outbox.send(signed, server: server, transport: Outbox.urlSession)
            var again = false
            for (change, reply) in zip(changes, replies) where journal.apply(reply, to: change) { again = true }
            save()
            guard again else { break }
        }
        scheduleWake()
    }

    /// The next flush: at the earliest removal time, or in a minute if a send failed.
    private func scheduleWake() {
        wake?.cancel()
        let removals = journal.records.compactMap { $0.waiting ? $0.removeAt : nil }.filter { $0 > .now }
        let retry: Date? = journal.records.contains { $0.waiting && $0.removeAt.map { $0 <= .now } ?? true } ? .now + 60 : nil
        guard let next = (removals + [retry].compactMap { $0 }).min() else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }
}
