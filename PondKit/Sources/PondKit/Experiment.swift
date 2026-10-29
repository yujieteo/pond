import Foundation

/// One small inner practice, in our own words, with credit to its public source (docs/concepts.md, Experiment).
public struct Experiment: Equatable, Identifiable, Sendable {
    public struct Credit: Equatable, Sendable {
        public var title: String
        public var link: URL
    }

    public var id: String
    public var title: String
    /// The line above the steps, for example "Pick one each day:".
    public var intro: String?
    public var steps: [String]
    /// The steps are activities to choose from, not a sequence.
    public var pickOne: Bool
    /// The starter experiments of the design board that this one comes from (X1 to X8).
    public var from: [String]
    public var credit: [Credit]

    /// The starter set: the captain kept X1 to X8 and dropped X9, then the board merged them into five,
    /// because they "boil down to feeling your feelings" (docs/concepts.md, Requirements deleted or changed).
    /// X6, X7 → E1. X4, X5 → E2. X1, X2 → E3. X3 → E4. X8 → E5.
    public static let starter: [Experiment] = [
        Experiment(id: "E1", title: "Feel it fully", intro: "Pick one each day:", steps: [
            "Name it, and find it in the body (2 minutes).",
            "Let it move: shake, stomp or hum (1 song).",
            "Write it raw: \"Right now I feel…\" (5 minutes).",
            "Say it to a friend or to a voice memo, with no fixing.",
            "Listen to their free Emotional Inquiry audio (8 minutes).",
        ], pickOne: true, from: ["X6", "X7"], credit: [
            aoa("How To Get Unstuck", "podcast/how-to-get-unstuck"),
            aoa("Experiments", "resources/experiments"),
            aoa("Emotional Inquiry audio", "resources/emotional-inquiry-audio"),
        ]),
        Experiment(id: "E2", title: "Align with a stuck task", intro: nil, steps: [
            "Name the task that you put off.",
            "Ask the part that says no: \"What speaks against this?\" Write each answer. Do not argue with it.",
            "Change the task until the no gets small: smaller, later or different.",
            "Do 5 minutes of the part that you know least, as play.",
        ], pickOne: false, from: ["X4", "X5"], credit: [
            aoa("How to End Procrastination Now", "podcast/how-to-end-procrastination-now"),
        ]),
        Experiment(id: "E3", title: "Do it restfully", intro: nil, steps: [
            "Do each usual task of the week in the most restful way that you can find.",
            "When you are tired, pick one thing from your recovery menu: a short list of what rests you.",
        ], pickOne: false, from: ["X1", "X2"], credit: [
            aoa("The Art of Rest and Recovery", "podcast/the-art-of-rest-and-recovery"),
        ]),
        Experiment(id: "E4", title: "Play first, edit later", intro: nil, steps: [
            "Do the first pass as play, with no judge.",
            "Do a later pass as a strict editor.",
        ], pickOne: false, from: ["X3"], credit: [
            aoa("How to End Procrastination Now", "podcast/how-to-end-procrastination-now"),
        ]),
        Experiment(id: "E5", title: "Let the good part land", intro: nil, steps: [
            "After something that you enjoyed, stay with the good part for 30 seconds.",
        ], pickOne: false, from: ["X8"], credit: [
            aoa("Experiments", "resources/experiments"),
        ]),
    ]

    public static func starter(_ id: String) -> Experiment? {
        starter.first { $0.id == id }
    }

    private static func aoa(_ title: String, _ path: String) -> Credit {
        Credit(title: title, link: URL(string: "https://www.artofaccomplishment.com/\(path)")!)
    }
}

/// One run of an experiment: a few days from `start`, then one optional "What did you notice?" line.
public struct Run: Codable, Equatable, Sendable {
    public var experiment: String
    /// YYYY-MM-DD, as an entry's `date`.
    public var start: String
    public var days: Int
    /// The days on which "Done" on the experiment's choice occurred.
    public var done: [String] = []
    /// The day of `close`. A run with no `closed` is the active run.
    public var closed: String?
    /// The notice line. It stays on the phone, unless it is published.
    public var notice: String?
    /// The id of the entry of kind note that published the notice.
    public var published: String?

    /// The day of the run that `date` is, from 1, or nil if the run does not offer that day.
    public func day(of date: String) -> Int? {
        guard let first = Run.number(start), let number = Run.number(date) else { return nil }
        let day = number - first + 1
        return (1...max(days, 1)).contains(day) ? day : nil
    }

    /// The days since 1970-01-01 of a YYYY-MM-DD date.
    static func number(_ date: String) -> Int? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return Int(day.timeIntervalSince1970 / 86400)
    }
}

/// The runs of experiments on the phone, the newest last. At most one run is active. All of it is private (R10).
public struct ExperimentLog: Codable, Equatable, Sendable {
    public static let days = 7

    public var runs: [Run] = []

    public init() {}

    public var active: Run? {
        runs.last.flatMap { $0.closed == nil ? $0 : nil }
    }

    /// Starts `id` on `date`. An active run closes first, with no notice.
    public mutating func start(_ id: String, on date: String, days: Int = ExperimentLog.days) {
        if active != nil { runs[runs.count - 1].closed = date }
        runs.append(Run(experiment: id, start: date, days: days))
    }

    /// "Done" on the experiment's choice counts the day once.
    public mutating func count(_ date: String) {
        guard var run = active, run.day(of: date) != nil, !run.done.contains(date) else { return }
        run.done.append(date)
        runs[runs.count - 1] = run
    }

    public mutating func close(on date: String, notice: String?) {
        guard active != nil else { return }
        runs[runs.count - 1].closed = date
        let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines)
        runs[runs.count - 1].notice = notice?.isEmpty == false ? notice : nil
    }

    /// Undo of `close`, before its 6 seconds end.
    public mutating func reopen() {
        guard let last = runs.indices.last, runs[last].closed != nil, runs[last].published == nil else { return }
        runs[last].closed = nil
        runs[last].notice = nil
    }

    /// The 4th choice of the menu on `date`, while the active run offers that day (docs/concepts.md, sync 7).
    public func choice(on date: String) -> Choice? {
        guard let run = active, let day = run.day(of: date), let experiment = Experiment.starter(run.experiment) else { return nil }
        return Choice(source: .experiment(id: run.experiment), why: "Experiment · day \(day) of \(run.days)",
                      entry: Entry(date: date, title: experiment.title, kind: .note))
    }

    /// The public entry of a published notice: the line, the experiment title and the credit link (sync 8).
    public static func noticeEntry(_ run: Run, date: String) -> Entry? {
        guard let notice = run.notice, let experiment = Experiment.starter(run.experiment) else { return nil }
        return Entry(date: date, title: "\(notice) (\(experiment.title))", link: experiment.credit.first?.link, kind: .note)
    }
}
