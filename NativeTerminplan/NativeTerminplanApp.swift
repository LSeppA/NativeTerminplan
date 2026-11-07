import SwiftUI
import Foundation

@MainActor
@main
struct NativeTerminplanApp: App {
    init() {
        #if DEBUG
        // App Group diagnostics (Debug only)
        let appGroupId = SharedConstants.appGroupId
        print("[AppGroup] Using id: \(appGroupId)")
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            print("[AppGroup] Container OK: \(url.path)")
        } else {
            print("[AppGroup] Container MISSING for identifier: \(appGroupId)")
        }
        if let defaults = UserDefaults(suiteName: appGroupId) {
            let smokeKey = "AppGroupSmokeTest"
            defaults.set(true, forKey: smokeKey)
            let smokeVal = defaults.bool(forKey: smokeKey)
            print("[AppGroup] UserDefaults(suiteName:) write/read test: \(smokeVal ? "SUCCESS" : "FAILED")")
            defaults.removeObject(forKey: smokeKey)
        } else {
            print("[AppGroup] UserDefaults(suiteName:) returned nil for \(appGroupId)")
        }
        #endif

        #if canImport(UserNotifications)
        NotificationService.shared.configure()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        #endif
    }

    var body: some Scene { WindowGroup { ContentView() } }
}

#if canImport(UserNotifications)
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private override init() {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == NotificationService.cancelActionIdentifier {
            await MainActor.run {
                let id = response.notification.request.identifier
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }
}
#endif



