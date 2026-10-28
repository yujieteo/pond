import SwiftUI

@main
struct PondApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TodayView()
                .environment(store)
                .preferredColorScheme(.light)
        }
        .onChange(of: phase) {
            // A new day gives a new menu, and a send that failed goes again.
            guard phase == .active else { return }
            store.refreshMenu()
            Task { await store.flush() }
        }
    }
}
