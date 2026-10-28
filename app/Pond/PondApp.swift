import SwiftUI
import UserNotifications

@main
struct PondApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = Store.shared
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
            store.offer()
            Task { await store.flush() }
        }
    }
}

/// The notification's buttons come here, also when the app is not open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        return true
    }

    // Not the async form: it calls its completion off the main thread, and UIKit stops the app for that.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let day = response.notification.request.content.userInfo["day"] as? String
        let action = response.actionIdentifier
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            if let day { await InviteNotifications.handle(action: action, day: day) }
            completion()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
