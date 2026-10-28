import Foundation
import Observation
import PondKit
import WidgetKit

/// The state of the app: the journal on the phone, the plan, the invite, the key and the sends.
/// One store serves the app, the notification and the widgets' buttons.
@Observable @MainActor
final class Store {
    static let shared = Store()

    private(set) var journal: Journal
    let plan: Plan
    private(set) var invite: Invite
    private(set) var key: Result<DeviceKey, Error>?

    /// "Every day" items (R13). They stay here until the plan editor (build step 11) keeps them in the plan.
    static let everyDay = ["RSS", "Textbook", "Fiction"]
    static let everyDaySlot = "Every day"

    /// The save service. A launch argument `-server http://127.0.0.1:8787` changes it for a local test server.
    let server = URL(string: UserDefaults.standard.string(forKey: "server") ?? "https://teoyujie.org")!

    private let file = URL.applicationSupportDirectory.appending(path: "journal.json")
    private var sending = false
    private var wake: Task<Void, Never>?
    private var scheduling: Task<Void, Never>?

    init() {
        journal = (try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))) ?? Journal()
        // The bundled copy of media-plan.md, until the app reads the site repo (build step 11).
        let text = Bundle.main.url(forResource: "media-plan", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        plan = Plan(markdown: text)
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

    private func offer(before: Invite) {
        let journal = journal
        invite.offer(plan: plan, journal: &self.journal, now: .now)
        if self.journal != journal { save() }
        if !inviteChanged(before) { schedule() }
    }

    /// A pick changes the notification in place and the widgets (sync 2 and 14).
    func pick(_ index: Int, on day: String) {
        let before = invite
        invite.pick(index, on: day)
        inviteChanged(before)
    }

    func unpick(on day: String) {
        let before = invite
        invite.unpick(on: day)
        inviteChanged(before)
    }

    /// "Done" in the app, the notification or a widget: records the pick, then signs and sends it (sync 3).
    /// With no network, the entry waits in the outbox.
    @discardableResult
    func done(on day: String) -> String? {
        let before = invite
        guard let entry = invite.done(on: day) else { return nil }
        let id = record(entry)
        inviteChanged(before)
        return id
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
            record(Entry(date: today, title: name, domain: 1, mode: .home, slot: Store.everyDaySlot))
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
