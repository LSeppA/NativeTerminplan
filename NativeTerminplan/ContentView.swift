import SwiftUI
import WidgetKit
import os
import Photos

#if canImport(UserNotifications)
import UserNotifications
#endif

#if DEBUG
// Shim to avoid build error if NotificationService isn't compiled in this target yet.
// Remove this once NotificationService.swift is part of the app target.
struct NotificationServiceShim {
    static func scheduleNotification(for: ScheduleItem) {}
}
#endif

#if !canImport(ActivityKit)
// Shim to avoid build error if ActivityKit isn't available or the manager isn't in this target.
enum LiveActivityManager {
    static func startOrUpdate(current: ScheduleItem?, next: ScheduleItem?) {}
    static func endAll() {}
}
#endif

struct ContentView: View {
    @StateObject private var store = ScheduleStore()
    @StateObject private var calendar = CalendarService()
    @State private var source: ImageSource?
    @State private var isRecognizing = false
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?
    @State private var showCaptureHint = false
    @State private var showInfo = false
    @AppStorage("hasAcceptedInfo") private var hasAcceptedInfo: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var nextUpdateTimer: Timer?
    @State private var nextUpdateTask: Task<Void, Never>?
    @State private var refreshToggle = false
    @State private var lastCapturedPhotoId: String?
    @State private var selectedPhotoId: String?
    @State private var selectedPhotoImage: UIImage?
    @State private var showPhotoViewer = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "ContentView")

    var body: some View {
        NavigationStack {
            Group {
                if store.days.isEmpty && !isRecognizing { emptyState }
                else { scheduleList }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("Mein Terminplan")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Button {
                            showInfo = true
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .imageScale(.medium)
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Informationen anzeigen")
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { showClearConfirmation = true } label: { Image(systemName: "trash") }
                        .disabled(store.days.isEmpty)
                        .accessibilityLabel("Alle Termine löschen")
                }
                ToolbarItem(placement: .topBarTrailing) { importMenu.disabled(!hasAcceptedInfo) }
#if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        insertTestAppointments()
                    } label: {
                        Label("Test", systemImage: "hammer")
                    }
                    .disabled(!hasAcceptedInfo)
                    .accessibilityLabel("Testtermine anlegen")
                }
#endif
            }
            .confirmationDialog("Gespeicherte Termine löschen?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Alle Termine löschen", role: .destructive) {
                    store.clear()
                    deleteAllImages()
                    #if canImport(UserNotifications)
                    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    #endif
                    NextAppointmentSharedStore.save(from: nil)
                    NextAppointmentSharedStore.saveList(from: [])
                    logger.info("Cleared all appointments and notifications; reloading widgets")
                    Task { @MainActor in
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
            .sheet(item: $source) { source in
                CameraPicker(sourceType: source.pickerSource) { image in
                    let url = saveImageToAppContainer(image)
                    if url == nil {
                        logger.error("Failed to persist captured/imported image to app container")
                    }
                    lastCapturedPhotoId = url?.path // reuse state to carry reference; will map to photoFileURL
                    recognize(image)
                }
            }
            .sheet(isPresented: $showInfo) {
                InfoSheetView(
                    hasAccepted: hasAcceptedInfo,
                    onAccept: {
                        hasAcceptedInfo = true
                        showInfo = false
                    },
                    onDecline: {
                        showInfo = false
                    }
                )
            }
            .sheet(isPresented: $showPhotoViewer) {
                NavigationStack {
                    Group {
                        if let img = selectedPhotoImage {
                            ZoomableImage(uiImage: img)
                                .background(Color(.systemBackground))
                        } else {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Lade Foto...")
                            }
                            .padding()
                        }
                    }
                    .navigationTitle("Foto")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fertig") { showPhotoViewer = false }
                        }
                    }
                    .onAppear {
                        reloadSelectedPhotoIfNeeded()
                    }
                }
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if showCaptureHint {
                        Text("Bitte prüfe die erfassten Daten mit den Terminen auf dem Papier. Falls Abweichungen bestehen, erstelle bitte eine neue Aufnahme direkt über dem Papier bis das Ergebnis brauchbar ist.")
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !hasAcceptedInfo {
                        Button {
                            showInfo = true
                        } label: {
                            Text("Zur Freischaltung zum Einlesen bitte zuerst Bedingungen akzeptieren!")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, showCaptureHint ? 0 : 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showCaptureHint)
            .animation(.easeInOut(duration: 0.25), value: hasAcceptedInfo)
            .alert("Hinweis", isPresented: Binding(get: { errorMessage != nil || calendar.errorMessage != nil }, set: { if !$0 { errorMessage = nil; calendar.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? calendar.errorMessage ?? "") }
            .task {
                if !hasAcceptedInfo {
                    showInfo = true
                }
                await cleanUpOldAppointments()
                await MainActor.run { scheduleFiveMinuteRefresh() }
                await MainActor.run {
                    let items = store.days.flatMap { $0.items }
                    NextAppointmentSharedStore.saveList(from: items)
                    NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: items))
                    WidgetCenter.shared.reloadAllTimelines()
                    logger.info("Startup: saved \(items.count) items to shared store and reloaded widgets")
                }
            }
            .onScenePhaseBecameActive {
                Task { await cleanUpOldAppointments() }
                scheduleFiveMinuteRefresh()
                let items = store.days.flatMap { $0.items }
                NextAppointmentSharedStore.saveList(from: items)
                NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: items))
                WidgetCenter.shared.reloadAllTimelines()
                logger.info("Scene active: saved \(items.count) items and reloaded widgets")
            }
        }
    }

    private func saveImageToAppContainer(_ image: UIImage) -> URL? {
        guard let base = SharedConstants.containerURL else { return nil }
        let photosDir = base.appendingPathComponent("Photos", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
            let filename = UUID().uuidString + ".jpg"
            let fileURL = photosDir.appendingPathComponent(filename)
            guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            logger.error("Failed to save image to app container: \(String(describing: error))")
            return nil
        }
    }

    private func photosDirectoryURL() -> URL? {
        SharedConstants.containerURL?.appendingPathComponent("Photos", isDirectory: true)
    }

    private func pruneUnreferencedImages() {
        guard let dir = photosDirectoryURL() else { return }
        let referenced: Set<String> = Set(store.days
            .flatMap { $0.items }
            .compactMap { $0.photoFileURL }
        )
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let path = file.path
            if !referenced.contains(path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func deleteAllImages() {
        guard let dir = photosDirectoryURL() else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func showPhoto(with identifier: String) {
        // Present the viewer immediately, then load the image asynchronously
        DispatchQueue.main.async {
            self.selectedPhotoId = identifier
            self.selectedPhotoImage = nil
            self.showPhotoViewer = true
        }

        // Try as file path first
        if FileManager.default.fileExists(atPath: identifier) {
            DispatchQueue.global(qos: .userInitiated).async {
                let image = UIImage(contentsOfFile: identifier)
                DispatchQueue.main.async {
                    self.selectedPhotoImage = image
                }
            }
            return
        }

        // Fallback: treat as Photos asset id
        let loadFromPhotos: () -> Void = {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject else { return }
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: PHImageManagerMaximumSize,
                                                  contentMode: .aspectFit,
                                                  options: options) { image, _ in
                DispatchQueue.main.async {
                    self.selectedPhotoImage = image
                }
            }
        }

        if #available(iOS 14.0, *) {
            DispatchQueue.main.async {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    if status == .authorized || status == .limited {
                        loadFromPhotos()
                    } else {
                        DispatchQueue.main.async {
                            self.errorMessage = "Kein Zugriff auf Fotos. Bitte in den Einstellungen erlauben."
                        }
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                PHPhotoLibrary.requestAuthorization { status in
                    if status == .authorized {
                        loadFromPhotos()
                    } else {
                        DispatchQueue.main.async {
                            self.errorMessage = "Kein Zugriff auf Fotos. Bitte in den Einstellungen erlauben."
                        }
                    }
                }
            }
        }
    }

    private func reloadSelectedPhotoIfNeeded() {
        guard showPhotoViewer, selectedPhotoImage == nil, let identifier = selectedPhotoId else { return }
        if FileManager.default.fileExists(atPath: identifier) {
            DispatchQueue.main.async {
                self.selectedPhotoImage = UIImage(contentsOfFile: identifier)
            }
            return
        }
        if #available(iOS 14.0, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if status == .authorized || status == .limited {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = assets.firstObject else { return }
                let options = PHImageRequestOptions()
                options.isSynchronous = false
                options.deliveryMode = .highQualityFormat
                options.version = .current
                PHImageManager.default().requestImage(for: asset,
                                                      targetSize: PHImageManagerMaximumSize,
                                                      contentMode: .aspectFit,
                                                      options: options) { image, _ in
                    DispatchQueue.main.async {
                        self.selectedPhotoImage = image
                    }
                }
            }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .authorized {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
                guard let asset = assets.firstObject else { return }
                let options = PHImageRequestOptions()
                options.isSynchronous = false
                options.deliveryMode = .highQualityFormat
                options.version = .current
                PHImageManager.default().requestImage(for: asset,
                                                      targetSize: PHImageManagerMaximumSize,
                                                      contentMode: .aspectFit,
                                                      options: options) { image, _ in
                    DispatchQueue.main.async {
                        self.selectedPhotoImage = image
                    }
                }
            }
        }
    }

    private var importMenu: some View {
        Menu {
            Button("Kamera", systemImage: "camera") { source = .camera }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Fotomediathek", systemImage: "photo") { source = .photoLibrary }
        } label: { Label("Einlesen", systemImage: "doc.text.viewfinder") }
    }

    private var emptyState: some View {
        ContentUnavailableView("Noch keine Termine", systemImage: "calendar", description: Text("Mit „Einlesen“ den Wochenplan fotografieren oder aus der Fotomediathek auswählen."))
    }

    private var scheduleList: some View {
        List {
            if let next = ScheduleStore.currentOrNext(from: store.days.flatMap { $0.items }) {
                let cal = Calendar.current
                let now = Date()
                let isCurrent: Bool = {
                    guard next.kind == .appointment, let start = next.startDate(calendar: cal) else { return false }
                    let end = next.endDate(calendar: cal) ?? start
                    return now >= start && now <= end
                }()
                Section(isCurrent ? "Jetzt" : "Als Nächstes") {
                    NextAppointmentCard(item: next, addToCalendar: { Task { await calendar.add(next) } }, onShowPhoto: { id in showPhoto(with: id) })
                        .task(id: next.id) {
                            NextAppointmentSharedStore.save(from: next)
                            await MainActor.run {
                                WidgetCenter.shared.reloadAllTimelines()
                                logger.info("Saved next appointment to shared store and reloaded widgets")
                            }
                        }
                }
            }
            ForEach(store.days) { day in
                Section(day.germanHeading) {
                    ForEach(day.items) { item in
                        ScheduleRow(item: item, addToCalendar: { Task { await calendar.add(item) } }, onShowPhoto: { id in showPhoto(with: id) })
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .id(refreshToggle)
    }

    private func cleanUpOldAppointments() async {
        // Flatten all items
        let allItems = store.days.flatMap { $0.items }
        let cal = Calendar.current
        let now = Date()
        // Determine past appointments
        let past = allItems.filter { item in
            guard item.kind == .appointment else { return false }
            let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
            let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
            return end < now
        }
        if past.isEmpty { return }
        // Remove past items from the store by rebuilding item list without them
        let remaining: [ScheduleItem] = allItems.filter { item in
            guard item.kind == .appointment else { return true }
            let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
            let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
            return end >= now
        }
        // Replace store content
        await MainActor.run { store.replace(with: remaining) }
        pruneUnreferencedImages()
        await MainActor.run { scheduleFiveMinuteRefresh() }
        // Cancel notifications for removed past appointments
        #if canImport(UserNotifications)
        for item in past { NotificationService.shared.cancelNotification(for: item) }
        #endif
        // Update shared store for widget
        await MainActor.run {
            NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: remaining))
            NextAppointmentSharedStore.saveList(from: remaining)
        }
    }

    private func recognize(_ image: UIImage) {
        isRecognizing = true // keep immediate visual feedback on main
        Task {
            do {
                let items = try await OCRService().recognizeSchedule(in: image)
                logger.info("OCR recognized \(items.count) items")
                // Filter out everything from and including the first occurrence of "Sehr verehrte" or "Sehr geehrte"
                let markers = ["sehr verehrte", "sehr geehrte"]
                let trimmedItems: [ScheduleItem] = {
                    if let idx = items.firstIndex(where: { item in
                        let t = item.title.lowercased()
                        return markers.contains(where: { t.contains($0) })
                    }) {
                        return Array(items.prefix(upTo: idx))
                    } else {
                        return items
                    }
                }()
                logger.info("Trimmed items count: \(trimmedItems.count)")
                await MainActor.run {
                    if trimmedItems.isEmpty { errorMessage = "Es wurden keine Termine oder Informationszeilen erkannt." }
                }
                if !trimmedItems.isEmpty {
                    // Identify past appointments to cancel notifications
                    let pastAppointments: [ScheduleItem] = trimmedItems.filter { item in
                        guard item.kind == .appointment else { return false }
                        let cal = Calendar.current
                        let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
                        let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
                        return end < Date()
                    }

                    let filtered: [ScheduleItem] = trimmedItems.filter { item in
                        guard item.kind == .appointment else { return true }
                        let cal = Calendar.current
                        let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
                        let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
                        return end >= Date()
                    }
                    logger.info("Filtered items count: \(filtered.count)")

                    var filteredWithPhoto: [ScheduleItem] = filtered
                    if let filePath = lastCapturedPhotoId {
                        filteredWithPhoto = filtered.map { item in
                            var copy = item
                            if item.kind == .appointment {
                                copy.photoFileURL = filePath
                            }
                            return copy
                        }
                    }

                    // Merge: replace only the days that were just scanned; keep other days intact
                    let cal = Calendar.current

                    // Existing items from the store
                    let existingItems = store.days.flatMap { $0.items }

                    // Determine affected days from the new scan
                    let affectedDays = Set(filteredWithPhoto.map { cal.startOfDay(for: $0.date) })

                    // Build a dictionary of existing items by day, then clear affected days
                    var itemsByDay = Dictionary(grouping: existingItems, by: { cal.startOfDay(for: $0.date) })
                    for day in affectedDays { itemsByDay[day] = [] }

                    // Group new items by day and insert them into the dictionary
                    let newItemsByDay = Dictionary(grouping: filteredWithPhoto, by: { cal.startOfDay(for: $0.date) })
                    for (day, newItems) in newItemsByDay { itemsByDay[day, default: []] = newItems }

                    // Flatten back to a single list, sorted by day then by start time
                    let merged: [ScheduleItem] = itemsByDay
                        .flatMap { $0.value }
                        .sorted { (a, b) in
                            let da = cal.startOfDay(for: a.date)
                            let db = cal.startOfDay(for: b.date)
                            if da != db { return da < db }
                            return (a.startMinutes ?? .max) < (b.startMinutes ?? .max)
                        }

                    await MainActor.run {
                        store.replace(with: merged)
                    }
                    pruneUnreferencedImages()
                    logger.info("Store replaced with merged items: \(merged.count)")
                    await MainActor.run { scheduleFiveMinuteRefresh() }

                    // Cancel notifications for removed past appointments (can be off-main)
                    for item in pastAppointments {
                        #if canImport(UserNotifications)
                        NotificationService.shared.cancelNotification(for: item)
                        #endif
                    }

                    // Cancel notifications for all appointments on affected days (old ones will be replaced)
                    let alreadyExistingItems = store.days.flatMap { $0.items }
                    let alreadyAffectedDays = Set(filteredWithPhoto.map { Calendar.current.startOfDay(for: $0.date) })
                    for item in alreadyExistingItems where item.kind == .appointment && alreadyAffectedDays.contains(Calendar.current.startOfDay(for: item.date)) {
                        #if canImport(UserNotifications)
                        NotificationService.shared.cancelNotification(for: item)
                        #endif
                    }

                    // Schedule notifications 10 minutes before start for remaining/new appointments on affected days
                    for item in filteredWithPhoto where item.kind == .appointment {
                        #if canImport(UserNotifications)
                        NotificationService.shared.scheduleNotification(for: item)
                        #else
                        NotificationServiceShim.scheduleNotification(for: item)
                        #endif
                    }

                    await MainActor.run {
                        NextAppointmentSharedStore.saveList(from: merged)
                        let currentOrNext = ScheduleStore.currentOrNext(from: merged)
                        NextAppointmentSharedStore.save(from: currentOrNext)
                        WidgetCenter.shared.reloadAllTimelines()
                        if #available(iOS 16.1, *) {
                            let now = Date()
                            let cal = Calendar.current
                            let current = merged.first(where: { item in
                                guard item.kind == .appointment, let start = item.startDate(calendar: cal) else { return false }
                                let end = item.endDate(calendar: cal) ?? start
                                return now >= start && now <= end
                            })
                        }
                    }

                    if #available(iOS 17.0, *) {
                        let now = Date()
                        let cal = Calendar.current
                        let current = merged.first(where: { item in
                            guard item.kind == .appointment, let start = item.startDate(calendar: cal) else { return false }
                            let end = item.endDate(calendar: cal) ?? start
                            return now >= start && now <= end
                        })
                        #if canImport(ActivityKit) && os(iOS)
                        await LiveActivityManager.startOrUpdate(current: current, next: ScheduleStore.currentOrNext(from: merged))
                        #else
                        LiveActivityManager.startOrUpdate(current: current, next: ScheduleStore.currentOrNext(from: merged))
                        #endif
                    }

                    await MainActor.run {
                        showCaptureHint = true
                    }
                    if #available(iOS 17.0, *) {
                        try? await Task.sleep(for: .seconds(3))
                    } else {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    await MainActor.run {
                        withAnimation { showCaptureHint = false }
                    }
                }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
            await MainActor.run { isRecognizing = false }
        }
    }

    private func scheduleFiveMinuteRefresh() {
        DispatchQueue.main.async {
            let items = store.days.flatMap { $0.items }
            logger.info("[Refresh] Scheduling 5-min refresh; items=\(items.count)")

            // Cancel previous timer and task
            nextUpdateTimer?.invalidate()
            nextUpdateTimer = nil
            nextUpdateTask?.cancel()
            nextUpdateTask = nil

            let cal = Calendar.current
            let now = Date()
            guard let current = items.first(where: { item in
                guard item.kind == .appointment, let start = item.startDate(calendar: cal) else { return false }
                let end = item.endDate(calendar: cal) ?? start
                return now >= start && now <= end
            }) else {
                // No current appointment: schedule an update at the next appointment start to keep widgets fresh
                logger.info("[Refresh] No current appointment; scheduling at next start + immediate reload")

                // Immediate widget reload with the latest 'next' info
                NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: items))
                NextAppointmentSharedStore.saveList(from: items)
                WidgetCenter.shared.reloadAllTimelines()

                // Find the next upcoming appointment start and schedule a task to update then
                if let nextUpcoming = items
                    .filter({ $0.kind == .appointment })
                    .compactMap({ item -> (Date, ScheduleItem)? in
                        guard let s = item.startDate(calendar: cal) else { return nil }
                        return (s, item)
                    })
                    .sorted(by: { $0.0 < $1.0 })
                    .first(where: { $0.0 > now }) {

                    let fireDate = nextUpcoming.0
                    let interval = fireDate.timeIntervalSince(now)
                    logger.info("[Refresh] Next-start scheduled at \(fireDate, privacy: .public) in \(interval, privacy: .public) seconds")

                    nextUpdateTask?.cancel()
                    nextUpdateTask = Task { @MainActor in
                        if #available(iOS 17.0, *) {
                            try? await Task.sleep(for: .seconds(interval))
                        } else {
                            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                        }
                        if Task.isCancelled { return }
                        // Run the same update routine we use elsewhere
                        await cleanUpOldAppointments()
                        let itemsNow = store.days.flatMap { $0.items }
                        NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: itemsNow))
                        NextAppointmentSharedStore.saveList(from: itemsNow)
                        WidgetCenter.shared.reloadAllTimelines()
                        logger.info("[Refresh] Next-start update: widgets reloaded")
                        await MainActor.run { refreshToggle.toggle() }
                        // Chain scheduling again after handling this update
                        await MainActor.run { scheduleFiveMinuteRefresh() }
                    }
                } else {
                    logger.info("[Refresh] No upcoming appointments to schedule against")
                }
                return
            }
            logger.info("[Refresh] Current appointment found: \(current.title, privacy: .public)")
            guard let start = current.startDate(calendar: cal) else { return }
            let end = current.endDate(calendar: cal) ?? start
            let threshold = start.addingTimeInterval(5 * 60)
            let nextFire = min(threshold, end)
            logger.info("[Refresh] Threshold=\(threshold, privacy: .public) end=\(end, privacy: .public) nextFire=\(nextFire, privacy: .public)")

            // Fine-tuning: also schedule a small post-end refresh (+10s) to smooth timing transitions
            let postEndOffset: TimeInterval = 10
            let postEndFire = end.addingTimeInterval(postEndOffset)
            let schedulePostEndRefresh = (nextFire == threshold) && (postEndFire > now)
            if schedulePostEndRefresh {
                let postInterval = postEndFire.timeIntervalSince(now)
                logger.info("Post-end refresh scheduled at \(postEndFire, privacy: .public) in \(postInterval, privacy: .public) seconds")
                Task { @MainActor in
                    if #available(iOS 17.0, *) {
                        try? await Task.sleep(for: .seconds(postInterval))
                    } else {
                        try? await Task.sleep(nanoseconds: UInt64(postInterval * 1_000_000_000))
                    }
                    if Task.isCancelled { return }
                    logger.info("Post-end refresh fired")
                    await cleanUpOldAppointments()
                    let itemsNow = store.days.flatMap { $0.items }
                    NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: itemsNow))
                    NextAppointmentSharedStore.saveList(from: itemsNow)
                    WidgetCenter.shared.reloadAllTimelines()
                    logger.info("Post-end refresh: widgets reloaded")
                    await MainActor.run { refreshToggle.toggle() }
                    // Schedule an exact end-time refresh to remove finished appointments and update widgets
                    await MainActor.run { scheduleFiveMinuteRefresh() }
                    if #available(iOS 16.1, *) {
                        let now = Date()
                        let cal = Calendar.current
                        let currentNow = itemsNow.first(where: { item in
                            guard item.kind == .appointment, let s = item.startDate(calendar: cal) else { return false }
                            let e = item.endDate(calendar: cal) ?? s
                            return now >= s && now <= e
                        })
                        #if canImport(ActivityKit) && os(iOS)
                        await LiveActivityManager.startOrUpdate(current: currentNow, next: ScheduleStore.currentOrNext(from: itemsNow))
                        #else
                        LiveActivityManager.startOrUpdate(current: currentNow, next: ScheduleStore.currentOrNext(from: itemsNow))
                        #endif
                    }
                }
            }

            let performUpdate: () -> Void = {
                Task {
                    await cleanUpOldAppointments()

                    let itemsNow = store.days.flatMap { $0.items }
                    logger.info("[Refresh] Update fired; itemsNow=\(itemsNow.count)")
                    NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: itemsNow))
                    NextAppointmentSharedStore.saveList(from: itemsNow)
                    WidgetCenter.shared.reloadAllTimelines()
                    logger.info("[Refresh] Update: widgets reloaded")
                    await MainActor.run { refreshToggle.toggle() }
                    if #available(iOS 16.1, *) {
                        let now = Date()
                        let currentNow = itemsNow.first(where: { item in
                            let cal = Calendar.current
                            guard item.kind == .appointment, let s = item.startDate(calendar: cal) else { return false }
                            let e = item.endDate(calendar: cal) ?? s
                            return now >= s && now <= e
                        })
                        #if canImport(ActivityKit) && os(iOS)
                        await LiveActivityManager.startOrUpdate(current: currentNow, next: ScheduleStore.currentOrNext(from: itemsNow))
                        #else
                        LiveActivityManager.startOrUpdate(current: currentNow, next: ScheduleStore.currentOrNext(from: itemsNow))
                        #endif
                    }
                    // Reschedule next check after performing update
                    await MainActor.run { scheduleFiveMinuteRefresh() }
                }
            }

            if now >= nextFire {
                logger.info("[Refresh] Scheduled time already passed; performing immediate update")
                performUpdate()
                return
            }

            let interval = nextFire.timeIntervalSince(now)
            logger.info("[Refresh] Task scheduled to fire in \(interval, privacy: .public) seconds")
            nextUpdateTask = Task { @MainActor in
                // Use a continuous clock to avoid issues with wall-clock changes
                if #available(iOS 17.0, *) {
                    try? await Task.sleep(for: .seconds(interval))
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                if Task.isCancelled { return }
                performUpdate()
            }
        }
    }

    private func insertTestAppointments() {
        let cal = Calendar.current
        let now = Date()
        let intervals: [(Int, String)] = [(1, "Test1"), (4, "Test 2"), (5, "Test 3")]
        let newItems: [ScheduleItem] = intervals.map { offsetMin, title in
            let startDate = now.addingTimeInterval(TimeInterval(offsetMin * 60))
            let startMinutes = cal.component(.hour, from: startDate) * 60 + cal.component(.minute, from: startDate)
            let duration = 3
            let endMinutes = startMinutes + duration
            return ScheduleItem(
                date: cal.startOfDay(for: startDate),
                startMinutes: startMinutes,
                endMinutes: endMinutes,
                durationMinutes: duration,
                title: title,
                location: "",
                note: "",
                kind: .appointment
            )
        }

        // Merge with existing items and persist
        let merged = store.days.flatMap { $0.items } + newItems
        store.replace(with: merged)

        // Schedule notifications for the test items
        #if canImport(UserNotifications)
        for item in newItems { NotificationService.shared.scheduleNotification(for: item) }
        #else
        for item in newItems { NotificationServiceShim.scheduleNotification(for: item) }
        #endif

        // Update shared store and widgets
        NextAppointmentSharedStore.saveList(from: merged)
        NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: merged))
        WidgetCenter.shared.reloadAllTimelines()

        // Reschedule 5-minute refresh and update live activity
        scheduleFiveMinuteRefresh()
        if #available(iOS 16.1, *) {
            let now = Date()
            let current = merged.first(where: { item in
                guard item.kind == .appointment, let start = item.startDate(calendar: cal) else { return false }
                let end = item.endDate(calendar: cal) ?? start
                return now >= start && now <= end
            })
            #if canImport(ActivityKit) && os(iOS)
            Task { await LiveActivityManager.startOrUpdate(current: current, next: ScheduleStore.currentOrNext(from: merged)) }
            #else
            LiveActivityManager.startOrUpdate(current: current, next: ScheduleStore.currentOrNext(from: merged))
            #endif
        }

        // Log
        logger.info("Inserted test appointments: \(newItems.count)")
    }
}

private struct NextAppointmentCard: View {
    let item: ScheduleItem
    let addToCalendar: () -> Void
    let onShowPhoto: ((String) -> Void)?

    private var isCurrent: Bool {
        let cal = Calendar.current
        guard item.kind == .appointment, let start = item.startDate(calendar: cal) else { return false }
        let end = item.endDate(calendar: cal) ?? start
        let now = Date()
        return now >= start && now <= end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(item.timeText, systemImage: "clock.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                if let id = item.photoFileURL ?? item.photoAssetLocalIdentifier {
                    Button {
                        onShowPhoto?(id)
                    } label: {
                        Image(systemName: "photo")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Foto anzeigen")
                    }
                    .buttonStyle(.plain)
                }
                if isCurrent {
                    Text("Jetzt")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Jetzt")
                }
            }
            Text(item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
        }
        .padding(.vertical, 6)
    }
}

private enum ImageSource: String, Identifiable {
    case camera, photoLibrary
    var id: String { rawValue }
    var pickerSource: UIImagePickerController.SourceType { self == .camera ? .camera : .photoLibrary }
}

private struct ScheduleRow: View {
    let item: ScheduleItem
    let addToCalendar: () -> Void
    let onShowPhoto: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.timeText).fontWeight(.semibold)
                if !item.durationText.isEmpty { Text(item.durationText).font(.caption).foregroundStyle(.secondary) }
            }.frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .fontWeight(item.kind == .information ? .medium : .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
                if !item.location.isEmpty { Text(item.location).font(.subheadline).foregroundStyle(.secondary) }
                if !item.note.isEmpty { Text(item.note).font(.footnote).italic().foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let id = item.photoFileURL ?? item.photoAssetLocalIdentifier {
                Button {
                    onShowPhoto?(id)
                } label: {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Foto anzeigen")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private extension ScheduleStore {
    static func currentOrNext(from items: [ScheduleItem]) -> ScheduleItem? {
        let cal = Calendar.current
        let now = Date()
        let appts = items.filter { $0.kind == .appointment }
        // Sort by start time
        let sorted = appts.sorted { a, b in
            let aStart = cal.date(bySettingHour: (a.startMinutes ?? 0) / 60, minute: (a.startMinutes ?? 0) % 60, second: 0, of: a.date) ?? a.date
            let bStart = cal.date(bySettingHour: (b.startMinutes ?? 0) / 60, minute: (b.startMinutes ?? 0) % 60, second: 0, of: b.date) ?? b.date
            return aStart < bStart
        }
        let grace: TimeInterval = 5 * 60
        // Prefer a current appointment only within the first 5 minutes after it started; otherwise show the next future one
        for appt in sorted {
            let start = cal.date(bySettingHour: (appt.startMinutes ?? 0) / 60, minute: (appt.startMinutes ?? 0) % 60, second: 0, of: appt.date) ?? appt.date
            let end = appt.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: appt.date) } ?? start
            if now >= start && now <= end {
                if now.timeIntervalSince(start) <= grace { return appt }
                // Past the grace period: continue searching for the next future appointment
                continue
            }
            if start > now { return appt }
        }
        return nil
    }
}

private extension View {
    @ViewBuilder
    func onScenePhaseBecameActive(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.modifier(ScenePhaseChange17(action: action))
        } else {
            self.modifier(ScenePhaseChange16(action: action))
        }
    }
}

private struct ScenePhaseChange17: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { action() }
        }
    }
}

private struct ScenePhaseChange16: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { action() }
            }
        } else {
            content.onChange(of: scenePhase) { phase in
                if phase == .active { action() }
            }
        }
    }
}

private struct ZoomableImage: View {
    let uiImage: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let magnification = MagnificationGesture()
                .onChanged { value in
                    let newScale = lastScale * value
                    scale = max(1, min(newScale, 4))
                }
                .onEnded { _ in
                    lastScale = scale
                }

            let drag = DragGesture()
                .onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                }
                .onEnded { _ in
                    lastOffset = offset
                }

            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnification)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) {
                    withAnimation(.spring()) {
                        if scale > 1 {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2
                            lastScale = 2
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: scale)
        }
        .background(Color.black.opacity(0.02))
    }
}
