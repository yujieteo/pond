import Foundation
import LocalAuthentication
import Observation
import PondKit
import Security

/// The plan editor's copy of media-plan.md, and its commit to the site repo (R8, docs/concepts.md, Plan).
/// There is no "save" step: the phone commits 7 seconds after the last change, after the 6 seconds of "Undo".
@Observable @MainActor
final class PlanSync {
    static let shared = PlanSync()
    static let delay: Duration = .seconds(7)

    enum Status: Equatable {
        /// The phone has the site copy, or the bundled copy before the first load.
        case current, waiting, noToken, refused(Int)
        /// The site copy changed after the phone's copy, so the phone loaded it, and its change went.
        case reloaded
    }

    private struct State: Codable {
        var text: String
        /// The Git blob SHA of the site copy that `text` comes from. None for the bundled copy.
        var sha: String?
        var waiting = false
    }

    private(set) var plan: Plan
    private(set) var status = Status.current
    private(set) var hasToken = PlanToken.exists
    private var state: State
    private var committing: Task<Void, Never>?
    /// The request to the site repo now. There is one at a time, so that a commit never uses a SHA that another commit made old.
    private var syncing: Task<Void, Never>?

    /// The GitHub API. A launch argument `-github http://127.0.0.1:9` changes it, for example to keep a test off the network.
    let api = URL(string: UserDefaults.standard.string(forKey: "github") ?? "https://api.github.com")!
    private let file = URL.applicationSupportDirectory.appending(path: "plan.json")

    /// The copy of media-plan.md in the app, until the first load from the site repo.
    static let bundled = Bundle.main.url(forResource: "media-plan", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    init() {
        let state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: file))) ?? State(text: PlanSync.bundled)
        self.state = state
        plan = Plan(markdown: state.text)
        if state.waiting { status = .waiting }
    }

    var text: String {
        switch status {
        case .current: state.sha == nil ? "The copy in the app. The site copy loads when the phone is online." : "Same as media-plan.md in the site repo."
        case .waiting: "Waiting to send to the site repo."
        case .noToken: "Not sent: add a GitHub token below."
        case .refused(let code): "Not sent: the site repo refused the token (\(code))."
        case .reloaded: "The site plan changed, so this phone loaded it. Make your change again."
        }
    }

    /// An edit of the plan: the menu changes at once, and the commit goes after `delay`.
    func change(_ edit: (inout Plan) -> Void) {
        var plan = plan
        edit(&plan)
        guard plan != self.plan else { return }
        state.waiting = true
        status = .waiting
        use(plan)
        committing?.cancel()
        committing = Task {
            try? await Task.sleep(for: PlanSync.delay)
            guard !Task.isCancelled else { return }
            await sync(load: false)
        }
    }

    /// When the app opens: sends a waiting change, or loads the site copy.
    func refresh() async {
        await sync(load: true)
    }

    func saveToken(_ token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        hasToken = PlanToken.save(token)
        if hasToken, state.waiting { await sync(load: false) }
    }

    func removeToken() {
        PlanToken.delete()
        hasToken = false
    }

    /// Sends a waiting change, or else loads the site copy if `load`, after the request before it.
    private func sync(load canLoad: Bool) async {
        while let syncing { await syncing.value }
        let task = Task {
            if state.waiting { await commit() } else if canLoad { await load() }
            syncing = nil
        }
        syncing = task
        await task.value
    }

    private func commit() async {
        guard state.waiting else { return }
        guard let sha = state.sha else {
            // A change of the bundled copy: it can go only if the site copy is the same as the bundled copy.
            guard let site = try? await PlanRepo.load(api: api, token: nil, transport: Outbox.urlSession) else { return }
            if site.text == PlanSync.bundled { state.sha = site.sha } else { return reload(site) }
            return await commit()
        }
        guard let token = await PlanToken.read() else {
            status = hasToken ? .waiting : .noToken
            return
        }
        let sent = state.text
        switch await PlanRepo.commit(sent, sha: sha, api: api, token: token, transport: Outbox.urlSession) {
        case .saved(let sha):
            state.sha = sha
            state.waiting = state.text != sent
            status = state.waiting ? .waiting : .current
            save()
        case .conflict:
            if let site = try? await PlanRepo.load(api: api, token: nil, transport: Outbox.urlSession) { reload(site) }
        case .refused(let code):
            status = .refused(code)
        case .later:
            status = .waiting
        }
    }

    private func load() async {
        guard let site = try? await PlanRepo.load(api: api, token: nil, transport: Outbox.urlSession), !state.waiting else { return }
        state = State(text: site.text, sha: site.sha)
        status = .current
        use(Plan(markdown: site.text))
    }

    private func reload(_ site: PlanRepo.File) {
        state = State(text: site.text, sha: site.sha)
        status = .reloaded
        use(Plan(markdown: site.text))
    }

    private func use(_ plan: Plan) {
        self.plan = plan
        save()
        Store.shared.setPlan(plan)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The GitHub token of the site repo, in the Keychain behind Face ID or the passcode (R8).
/// Make it a fine-grained token with "Contents: read and write" on the site repo only.
enum PlanToken {
    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "org.teoyujie.pond.github", kSecAttrAccount: PlanRepo.repo]
    }

    static func save(_ token: String) -> Bool {
        delete()
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil) else {
            return false
        }
        var item = query
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrAccessControl] = access
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Asks for Face ID. The Keychain blocks its thread while it asks, so the read is off the main thread.
    static func read() async -> String? {
        await Task.detached {
            let context = LAContext()
            context.localizedReason = "Send the plan to the site repo"
            var read = query
            read[kSecReturnData] = true
            read[kSecUseAuthenticationContext] = context
            var data: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// The token is there, with no Face ID: a read that must not ask gets "interaction not allowed".
    static var exists: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var check = query
        check[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(check as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
