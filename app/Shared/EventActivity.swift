import ActivityKit
import AppIntents
import Foundation
import PondKit

/// The Live Activity of a live event on its day (R15): on the Lock Screen and in the Dynamic Island,
/// with "Go" and "Done", so that the event needs no open of the app.
struct EventAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Done" recorded the event: the activity shows "In your log" and then goes.
        var done = false
    }

    var id: String
    /// YYYY-MM-DD, the invite day of the event.
    var day: String
    var title: String
    var place: String
    var start: Date
    var cost: String?
    var directions: URL
}

/// "Done" on the Live Activity: the same action as "Done" on the event's choice (docs/concepts.md, sync 3).
struct EventDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done"
    static let isDiscoverable = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    @Parameter(title: "Day") var day: String
    @Parameter(title: "Event") var id: String

    init() {}

    init(day: String, id: String) {
        self.day = day
        self.id = id
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await Store.shared.doneEvent(id, on: day)
        await Store.shared.finish()
        #endif
        return .result()
    }
}
