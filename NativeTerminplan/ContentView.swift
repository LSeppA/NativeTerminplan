import SwiftUI

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

struct ContentView: View {
    @StateObject private var store = ScheduleStore()
    @StateObject private var calendar = CalendarService()
    @State private var source: ImageSource?
    @State private var isRecognizing = false
    @State private var showClearConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.days.isEmpty && !isRecognizing { emptyState }
                else { scheduleList }
            }
            .navigationTitle("Mein Terminplan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { showClearConfirmation = true } label: { Image(systemName: "trash") }
                        .disabled(store.days.isEmpty)
                        .accessibilityLabel("Alle Termine löschen")
                }
                ToolbarItem(placement: .topBarTrailing) { importMenu }
            }
            .confirmationDialog("Gespeicherte Termine löschen?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
                Button("Alle Termine löschen", role: .destructive) {
                    store.clear()
                    #if canImport(UserNotifications)
                    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    #endif
                }
            }
            .sheet(item: $source) { source in CameraPicker(sourceType: source.pickerSource) { image in recognize(image) } }
            .overlay { if isRecognizing { ProgressView("Terminplan wird gelesen …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .alert("Hinweis", isPresented: Binding(get: { errorMessage != nil || calendar.errorMessage != nil }, set: { if !$0 { errorMessage = nil; calendar.errorMessage = nil } })) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? calendar.errorMessage ?? "") }
            .task { await cleanUpOldAppointments() }
        }
    }

    private var importMenu: some View {
        Menu {
            Button("Kamera", systemImage: "camera") { source = .camera }
            Button("Fotomediathek", systemImage: "photo") { source = .photoLibrary }
        } label: { Label("Einlesen", systemImage: "doc.text.viewfinder") }
    }

    private var emptyState: some View {
        ContentUnavailableView("Noch keine Termine", systemImage: "calendar", description: Text("Mit „Einlesen“ den Wochenplan fotografieren oder aus der Fotomediathek auswählen."))
    }

    private var scheduleList: some View {
        List {
            if let next = store.nextAppointment {
                Section("Als Nächstes") {
                    NextAppointmentCard(item: next) { Task { await calendar.add(next) } }
                        .task { NextAppointmentSharedStore.save(from: next) }
                }
            }
            ForEach(store.days) { day in
                Section(day.germanHeading) {
                    ForEach(day.items) { item in ScheduleRow(item: item) { Task { await calendar.add(item) } }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
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
        store.replace(with: remaining)
        // Cancel notifications for removed past appointments
        #if canImport(UserNotifications)
        for item in past { NotificationService.shared.cancelNotification(for: item) }
        #endif
        // Update shared store for widget
        NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: remaining))
    }

    private func recognize(_ image: UIImage) {
        isRecognizing = true
        Task {
            do {
                let items = try await OCRService().recognizeSchedule(in: image)
                if items.isEmpty { errorMessage = "Es wurden keine Termine oder Informationszeilen erkannt." }
                else {
                    // Identify past appointments to cancel notifications
                    let pastAppointments: [ScheduleItem] = items.filter { item in
                        guard item.kind == .appointment else { return false }
                        let cal = Calendar.current
                        let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
                        let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
                        return end < Date()
                    }

                    // Remove past appointments (keep current and future)
                    let filtered: [ScheduleItem] = items.filter { item in
                        guard item.kind == .appointment else { return true }
                        let cal = Calendar.current
                        let start = cal.date(bySettingHour: (item.startMinutes ?? 0) / 60, minute: (item.startMinutes ?? 0) % 60, second: 0, of: item.date) ?? item.date
                        let end = item.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: item.date) } ?? start
                        return end >= Date()
                    }

                    store.replace(with: filtered)

                    // Cancel notifications for removed past appointments
                    for item in pastAppointments {
                        #if canImport(UserNotifications)
                        NotificationService.shared.cancelNotification(for: item)
                        #else
                        // no-op in shim
                        #endif
                    }

                    // Schedule notifications 10 minutes before start for remaining appointments
                    for item in filtered where item.kind == .appointment {
                        #if canImport(UserNotifications)
                        NotificationService.shared.scheduleNotification(for: item)
                        #else
                        NotificationServiceShim.scheduleNotification(for: item)
                        #endif
                    }

                    // Save current or next appointment for the widget
                    NextAppointmentSharedStore.save(from: ScheduleStore.currentOrNext(from: filtered))
                }
            } catch { errorMessage = error.localizedDescription }
            isRecognizing = false
        }
    }
}

private struct NextAppointmentCard: View {
    let item: ScheduleItem
    let addToCalendar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.timeText, systemImage: "clock.fill")
                .font(.headline)
                .foregroundStyle(.tint)
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
        // Prefer a current appointment (now between start and end), otherwise next future one
        for appt in sorted {
            let start = cal.date(bySettingHour: (appt.startMinutes ?? 0) / 60, minute: (appt.startMinutes ?? 0) % 60, second: 0, of: appt.date) ?? appt.date
            let end = appt.endMinutes.flatMap { em in cal.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: appt.date) } ?? start
            if now >= start && now <= end { return appt }
            if start > now { return appt }
        }
        return nil
    }
}
