import Foundation
import Observation
import PondKit

/// The state of the app: the journal on the phone, the plan, the key and the sends.
@Observable @MainActor
final class Store {
    private(set) var journal: Journal
    let plan: Plan
    private(set) var key: Result<DeviceKey, Error>?
    private(set) var choices: [Choice] = []

    /// "Every day" items (R13). They stay here until the plan editor (build step 11) keeps them in the plan.
    static let everyDay = ["RSS", "Textbook", "Fiction"]
    static let everyDaySlot = "Every day"

    /// The save service. A launch argument `-server http://127.0.0.1:8787` changes it for a local test server.
    let server = URL(string: UserDefaults.standard.string(forKey: "server") ?? "https://teoyujie.org")!

    private let file = URL.applicationSupportDirectory.appending(path: "journal.json")
    private var sending = false
    private var wake: Task<Void, Never>?

    init() {
        journal = (try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: file))) ?? Journal()
        // The bundled copy of media-plan.md, until the app reads the site repo (build step 11).
        let text = Bundle.main.url(forResource: "media-plan", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        plan = Plan(markdown: text)
        refreshMenu()
    }

    var today: String { Menu.day(.now) }

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

    func refreshMenu() {
        choices = Menu.choices(plan: plan, journal: journal, date: .now)
        for case .enjoyed(let id) in choices.map(\.source) where journal[id]?.offered != today {
            journal.offer(id, on: today)
            save()
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
        refreshMenu()
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
