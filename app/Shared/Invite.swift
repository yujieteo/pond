import AppIntents
import Foundation
import PondKit

/// The App Group of the app and the widgets: the app writes invite.json, and the widgets read it.
enum SharedInvite {
    static let group = "group.org.teoyujie.pond"

    static var file: URL {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? .applicationSupportDirectory
        return dir.appending(path: "invite.json")
    }

    static func load() -> Invite {
        (try? JSONDecoder().decode(Invite.self, from: Data(contentsOf: file))) ?? Invite()
    }

    static func save(_ invite: Invite) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(invite).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension Choice {
    var icon: String {
        switch source {
        case .slot: entry.domain == 2 ? "🎵" : entry.domain == 5 ? "🎬" : "📄"
        case .enjoyed: "🎵"
        case .notVisited: entry.mode == .live ? "🎟" : "🧭"
        case .experiment: "🌱"
        case .event: "🎟"
        }
    }
}

// The widgets' buttons. A LiveActivityIntent runs in the app's process, so "Done" in a widget is the same action
// as "Done" in the notification, with the same journal, key and outbox (docs/concepts.md, sync 14).
// The widget target has the WIDGET condition: it only shows the buttons.

struct PickIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pick"
    static let isDiscoverable = false

    @Parameter(title: "Day") var day: String
    @Parameter(title: "Choice") var index: Int

    init() {}

    init(day: String, index: Int) {
        self.day = day
        self.index = index
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await Store.shared.pick(index, on: day)
        await Store.shared.finish()
        #endif
        return .result()
    }
}

struct UnpickIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Something else"
    static let isDiscoverable = false

    @Parameter(title: "Day") var day: String

    init() {}

    init(day: String) { self.day = day }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await Store.shared.unpick(on: day)
        await Store.shared.finish()
        #endif
        return .result()
    }
}

/// "Done" signs with the phone key, and the Secure Enclave key needs an unlocked phone: on the Lock Screen, it asks for unlock.
struct DoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done"
    static let isDiscoverable = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Day") var day: String

    init() {}

    init(day: String) { self.day = day }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await Store.shared.done(on: day)
        await Store.shared.finish()
        #endif
        return .result()
    }
}
