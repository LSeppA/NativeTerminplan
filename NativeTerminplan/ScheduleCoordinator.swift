import Combine
import Foundation
import os
import UIKit
import WidgetKit

#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
final class ScheduleCoordinator: ObservableObject {
    @Published var refreshToken = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "ScheduleCoordinator")
    private let photoStore: PhotoStore
    private var refreshTasks: [Task<Void, Never>] = []

    init(photoStore: PhotoStore = PhotoStore()) {
        self.photoStore = photoStore
    }

    func savePhoto(_ image: UIImage) -> URL? {
        let url = photoStore.save(image)
        if url == nil {
            logger.error("Failed to persist captured/imported image to app container")
        }
        return url
    }

    func showPhoto(identifier: String, completion: @escaping (Result<UIImage, PhotoStoreError>) -> Void) {
        photoStore.loadImage(identifier: identifier, completion: completion)
    }

    func clearAll(in store: ScheduleStore) {
        store.clear()
        photoStore.deleteAllImages()
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        #endif
        NextAppointmentSharedStore.save(from: nil)
        NextAppointmentSharedStore.saveList(from: [])
        WidgetCenter.shared.reloadAllTimelines()
        cancelScheduledRefreshes()
        if #available(iOS 16.1, *) {
            Task { await LiveActivityManager.endAll() }
        }
        logger.info("Cleared all appointments and notifications; reloaded widgets")
    }

    func handleStartup(store: ScheduleStore) async {
        await cleanUpOldAppointments(in: store)
        scheduleRefresh(for: store)
        syncSharedSchedule(with: store.days.flatMap { $0.items })
    }

    func handleSceneBecameActive(store: ScheduleStore) {
        Task {
            await cleanUpOldAppointments(in: store)
            scheduleRefresh(for: store)
        }
        syncSharedSchedule(with: store.days.flatMap { $0.items })
    }

    func previewImport(from image: UIImage, photoPath: String?, existingItems: [ScheduleItem]) async throws -> ScheduleImportResult {
        let recognizedItems = try await OCRService().recognizeSchedule(in: image)
        logger.info("OCR recognized \(recognizedItems.count) items")

        let importResult = ScheduleLogic.prepareImport(
            recognizedItems: recognizedItems,
            existingItems: existingItems,
            photoPath: photoPath
        )
        logger.info("Trimmed items count: \(importResult.trimmedItems.count)")
        logger.info("Imported active items count: \(importResult.importedItems.count)")
        return importResult
    }

    func commitImport(importedItems: [ScheduleItem], skippedPastAppointments: [ScheduleItem], into store: ScheduleStore) async {
        guard !importedItems.isEmpty else { return }

        let existingItems = store.days.flatMap { $0.items }
        let replacedAppointments = ScheduleLogic.appointmentsOnAffectedDays(replacedBy: importedItems, in: existingItems)
        let mergedItems = ScheduleLogic.mergeImportedItems(importedItems, into: existingItems)

        store.replace(with: mergedItems)
        pruneUnreferencedImages(for: store)
        syncSharedSchedule(with: mergedItems)
        scheduleRefresh(for: store)

        let notificationsToCancel = skippedPastAppointments + replacedAppointments
        cancelNotifications(for: notificationsToCancel)
        scheduleNotifications(for: importedItems)

        if #available(iOS 17.0, *) {
            await updateLiveActivity(with: mergedItems)
        }
    }

    func insertDebugAppointments(into store: ScheduleStore) {
        let calendar = Calendar.current
        let now = Date()
        let intervals: [(Int, String)] = [(1, "Test1"), (4, "Test 2"), (5, "Test 3")]
        let newItems: [ScheduleItem] = intervals.map { offsetMin, title in
            let startDate = now.addingTimeInterval(TimeInterval(offsetMin * 60))
            let startMinutes = calendar.component(.hour, from: startDate) * 60 + calendar.component(.minute, from: startDate)
            let duration = 3
            return ScheduleItem(
                date: calendar.startOfDay(for: startDate),
                startMinutes: startMinutes,
                endMinutes: startMinutes + duration,
                durationMinutes: duration,
                title: title,
                location: "",
                note: "",
                kind: .appointment
            )
        }

        let merged = store.days.flatMap { $0.items } + newItems
        store.replace(with: merged)
        scheduleNotifications(for: newItems)
        syncSharedSchedule(with: merged)
        scheduleRefresh(for: store)

        if #available(iOS 16.1, *) {
            Task { await updateLiveActivity(with: merged) }
        }
        logger.info("Inserted test appointments: \(newItems.count)")
    }

    func cleanUpOldAppointments(in store: ScheduleStore) async {
        let allItems = store.days.flatMap { $0.items }
        let pastAppointments = allItems.filter { ScheduleLogic.isPastAppointment($0) }
        guard !pastAppointments.isEmpty else { return }

        let remaining = ScheduleLogic.activeItems(from: allItems)
        store.replace(with: remaining)
        pruneUnreferencedImages(for: store)
        syncSharedSchedule(with: remaining)
        cancelNotifications(for: pastAppointments)
    }

    func scheduleRefresh(for store: ScheduleStore) {
        let items = store.days.flatMap { $0.items }
        logger.info("[Refresh] Scheduling refresh; items=\(items.count)")

        cancelScheduledRefreshes()

        let now = Date()
        guard let current = ScheduleLogic.currentAppointment(in: items, now: now) else {
            logger.info("[Refresh] No current appointment; scheduling at next start + immediate reload")
            syncSharedSchedule(with: items)

            guard let fireDate = ScheduleLogic.nextUpcomingStart(in: items, after: now) else {
                logger.info("[Refresh] No upcoming appointments to schedule against")
                return
            }
            scheduleOneShotRefresh(after: fireDate.timeIntervalSince(now), store: store, label: "Next-start")
            return
        }

        logger.info("[Refresh] Current appointment found: \(current.title, privacy: .public)")
        let next = nextAppointment(after: current, in: items)
        guard let end = current.endDate() ?? current.startDate() else { return }

        if now < end.addingTimeInterval(-5 * 60) {
            let switchDate = max(Date(), end.addingTimeInterval(-5 * 60))
            scheduleOneShotRefresh(after: switchDate.timeIntervalSince(now), store: store, label: "Upcoming-before-end")
        } else {
            let clearDate = end.addingTimeInterval(1)
            scheduleOneShotRefresh(after: max(0, clearDate.timeIntervalSince(now)), store: store, label: next == nil ? "Last-end" : "Current-end")
        }
    }

    private func scheduleOneShotRefresh(after interval: TimeInterval, store: ScheduleStore, label: String) {
        logger.info("[Refresh] \(label, privacy: .public) refresh scheduled in \(interval, privacy: .public) seconds")
        let task = Task { @MainActor in
            await sleep(for: interval)
            guard !Task.isCancelled else { return }
            await runScheduledRefresh(store: store, label: label)
        }
        refreshTasks.append(task)
    }

    private func cancelScheduledRefreshes() {
        refreshTasks.forEach { $0.cancel() }
        refreshTasks.removeAll()
    }

    private func runScheduledRefresh(store: ScheduleStore, label: String) async {
        await cleanUpOldAppointments(in: store)
        let itemsNow = store.days.flatMap { $0.items }
        syncSharedSchedule(with: itemsNow)
        logger.info("[Refresh] \(label, privacy: .public) update: widgets reloaded")
        refreshToken.toggle()
        if #available(iOS 16.1, *) {
            await updateLiveActivity(with: itemsNow)
        }
        scheduleRefresh(for: store)
    }

    private func syncSharedSchedule(with items: [ScheduleItem]) {
        NextAppointmentSharedStore.saveList(from: items)
        NextAppointmentSharedStore.save(from: ScheduleLogic.currentOrNext(from: items))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func nextAppointment(after current: ScheduleItem, in items: [ScheduleItem]) -> ScheduleItem? {
        guard let currentStart = current.startDate() else { return nil }
        return ScheduleLogic.sorted(items)
            .filter { $0.kind == .appointment }
            .first { item in
                guard let start = item.startDate() else { return false }
                return start > currentStart
            }
    }

    private func pruneUnreferencedImages(for store: ScheduleStore) {
        let referencedPaths = Set(store.days.flatMap { $0.items }.compactMap { $0.photoFileURL })
        photoStore.pruneUnreferencedImages(referencedPaths: referencedPaths)
    }

    private func cancelNotifications(for items: [ScheduleItem]) {
        #if canImport(UserNotifications)
        for item in items where item.kind == .appointment {
            NotificationService.shared.cancelNotification(for: item)
        }
        #endif
    }

    private func scheduleNotifications(for items: [ScheduleItem]) {
        for item in items where item.kind == .appointment {
            #if canImport(UserNotifications)
            NotificationService.shared.scheduleNotification(for: item)
            #else
            NotificationServiceShim.scheduleNotification(for: item)
            #endif
        }
    }

    private func updateLiveActivity(with items: [ScheduleItem]) async {
        #if canImport(ActivityKit) && os(iOS)
        await LiveActivityManager.startOrUpdate(
            current: ScheduleLogic.currentAppointment(in: items),
            next: ScheduleLogic.currentOrNext(from: items)
        )
        #else
        LiveActivityManager.startOrUpdate(
            current: ScheduleLogic.currentAppointment(in: items),
            next: ScheduleLogic.currentOrNext(from: items)
        )
        #endif
    }

    private func sleep(for interval: TimeInterval) async {
        if #available(iOS 17.0, *) {
            try? await Task.sleep(for: .seconds(interval))
        } else {
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    }
}
