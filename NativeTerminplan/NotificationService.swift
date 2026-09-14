import Foundation
import UserNotifications

final class NotificationService {
    static let shared = NotificationService()
    private init() {}

    static let cancelActionIdentifier = "ALARM_CANCEL_ACTION"
    static let categoryIdentifier = "APPOINTMENT_ALARM_CATEGORY"

    func configure() {
        let cancel = UNNotificationAction(identifier: Self.cancelActionIdentifier, title: "Abbrechen", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [cancel], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        requestAuthorizationIfNeeded()
    }

    private func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus != .authorized else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func scheduleNotification(for item: ScheduleItem) {
        guard let startMinutes = item.startMinutes else { return }
        // Fire 10 minutes before start
        let fireDate = Calendar.current.date(byAdding: .minute, value: -10, to: date(item.date, minutes: startMinutes))
        guard let fireDate, fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Termin in 10 Minuten"
        content.body = bodyText(for: item)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
        let request = UNNotificationRequest(identifier: notificationId(for: item), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelNotification(for item: ScheduleItem) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId(for: item)])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId(for: item)])
    }

    private func notificationId(for item: ScheduleItem) -> String {
        // Unique per date+title+start
        let dateKey = ISO8601DateFormatter().string(from: item.date)
        let startKey = item.startMinutes.map(String.init) ?? "noStart"
        return "appt_\(dateKey)_\(startKey)_\(item.title)"
    }

    private func date(_ day: Date, minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    private func bodyText(for item: ScheduleItem) -> String {
        var parts: [String] = []
        parts.append(item.timeText)
        parts.append(item.title)
        if !item.location.isEmpty { parts.append(item.location) }
        return parts.joined(separator: " • ")
    }
}
