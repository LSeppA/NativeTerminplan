import Foundation
import ActivityKit
import os

@available(iOS 16.1, *)
struct AppointmentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var title: String
        var startDate: Date
        var location: String?
    }
}

@available(iOS 16.1, *)
@MainActor
enum LiveActivityManager {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "LiveActivity")

    // MARK: - Helpers for iOS 16.1 (deprecated in 16.2)
    @available(iOS, introduced: 16.1, deprecated: 16.2)
    private static func updatePre162(_ activity: Activity<AppointmentActivityAttributes>, with state: AppointmentActivityAttributes.ContentState) async {
        await activity.update(using: state)
    }

    @available(iOS, introduced: 16.1, deprecated: 16.2)
    @discardableResult
    private static func requestPre162(attributes: AppointmentActivityAttributes, state: AppointmentActivityAttributes.ContentState) throws -> Activity<AppointmentActivityAttributes> {
        try Activity.request(attributes: attributes, contentState: state)
    }

    @available(iOS, introduced: 16.1, deprecated: 16.2)
    private static func endPre162(_ activity: Activity<AppointmentActivityAttributes>) async {
        await activity.end(dismissalPolicy: ActivityUIDismissalPolicy.immediate)
    }

    static func startOrUpdate(current: ScheduleItem?, next: ScheduleItem?) async {
        let currentTitle = current?.title ?? "nil"
        let nextTitle = next?.title ?? "nil"
        logger.info("LiveActivity startOrUpdate called: current=\(currentTitle, privacy: .public), next=\(nextTitle, privacy: .public)")
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        logger.info("LiveActivity: activities enabled")

        guard let display = displayItem(current: current, next: next),
              let start = display.item.startDate() else {
            logger.info("LiveActivity: no item to display; ending all activities")
            await endAll()
            return
        }

        let state = AppointmentActivityAttributes.ContentState(
            status: display.status,
            title: display.item.title,
            startDate: start,
            location: display.item.location.isEmpty ? nil : display.item.location
        )

        // If an activity exists, update it; otherwise, start a new one
        if let activity = Activity<AppointmentActivityAttributes>.activities.first {
            logger.info("LiveActivity: updating existing activity")
            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: state, staleDate: nil)
                await activity.update(content)
                logger.info("LiveActivity: request/update succeeded")
            } else {
                await updatePre162(activity, with: state)
                logger.info("LiveActivity: request/update succeeded")
            }
        } else {
            logger.info("LiveActivity: requesting new activity")
            let attributes = AppointmentActivityAttributes()
            do {
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: state, staleDate: nil)
                    _ = try Activity.request(attributes: attributes, content: content)
                    logger.info("LiveActivity: request/update succeeded")
                } else {
                    _ = try requestPre162(attributes: attributes, state: state)
                    logger.info("LiveActivity: request/update succeeded")
                }
            } catch {
                logger.error("[LiveActivity] Request failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func endAll() async {
        logger.info("LiveActivity: ending all activities")
        for activity in Activity<AppointmentActivityAttributes>.activities {
            if #available(iOS 16.2, *) {
                await activity.end(nil, dismissalPolicy: ActivityUIDismissalPolicy.immediate)
            } else {
                await endPre162(activity)
            }
        }
    }

    private static func displayItem(current: ScheduleItem?, next: ScheduleItem?, now: Date = Date()) -> (status: String, item: ScheduleItem)? {
        guard let current else {
            return next.map { ("Demnächst", $0) }
        }

        guard let end = current.endDate() else {
            return ("Jetzt", current)
        }

        if let next, now >= end.addingTimeInterval(-5 * 60) {
            return ("Demnächst", next)
        }

        return ("Jetzt", current)
    }
}
