import Foundation
import UniformTypeIdentifiers

struct NextAppointmentSnapshot: Codable {
    var date: Date
    var startMinutes: Int?
    var endMinutes: Int?
    var durationMinutes: Int?
    var title: String
    var location: String
}

enum NextAppointmentSharedStore {
    private static var defaults: UserDefaults? {
        let suite = SharedConstants.appGroupId
        if let ud = UserDefaults(suiteName: suite) {
            return ud
        } else {
            #if DEBUG
            print("[NextAppointmentSharedStore] Failed to get UserDefaults for suite: \(suite). Check App Group capability and identifier.")
            #endif
            return nil
        }
    }
    
    private static let upcomingKey = "upcomingAppointments"
    
    // File-based persistence (robust across processes)
    private static let snapshotsFileName = "next_appointment.json"
    private static let listFileName = "upcoming_appointments.json"

    private static var containerDirectory: URL? {
        SharedConstants.containerURL
    }

    private static var snapshotsFileURL: URL? {
        containerDirectory?.appendingPathComponent(snapshotsFileName, conformingTo: .json)
    }

    private static var listFileURL: URL? {
        containerDirectory?.appendingPathComponent(listFileName, conformingTo: .json)
    }

    static func save(from item: ScheduleItem?) {
        guard let item else {
            if let defaults { defaults.removeObject(forKey: SharedConstants.nextAppointmentKey) }
            if let url = snapshotsFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        let snapshot = NextAppointmentSnapshot(date: item.date, startMinutes: item.startMinutes, endMinutes: item.endMinutes, durationMinutes: item.durationMinutes, title: item.title, location: item.location)
        if let data = try? JSONEncoder().encode(snapshot) {
            if let defaults = defaults {
                defaults.set(data, forKey: SharedConstants.nextAppointmentKey)
                saveList(from: [item])
            } else {
                #if DEBUG
                print("[NextAppointmentSharedStore] Defaults unavailable; cannot save snapshot.")
                #endif
            }
            if let url = snapshotsFileURL {
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    #if DEBUG
                    print("[NextAppointmentSharedStore] Failed to write snapshot file: \(error)")
                    #endif
                }
            }
        }
    }

    static func load() -> NextAppointmentSnapshot? {
        // Prefer file-based snapshot for robustness
        if let url = snapshotsFileURL, let data = try? Data(contentsOf: url), let snap = try? JSONDecoder().decode(NextAppointmentSnapshot.self, from: data) {
            return snap
        }
        // Fallback to UserDefaults
        guard let defaults = defaults, let data = defaults.data(forKey: SharedConstants.nextAppointmentKey) else {
            #if DEBUG
            print("[NextAppointmentSharedStore] No snapshot data available in file or defaults.")
            #endif
            return nil
        }
        return try? JSONDecoder().decode(NextAppointmentSnapshot.self, from: data)
    }
    
    static func saveList(from items: [ScheduleItem]) {
        guard let defaults = defaults else {
            #if DEBUG
            print("[NextAppointmentSharedStore] Defaults unavailable; cannot save list.")
            #endif
            return
        }
        // Store only appointments, in chronological order, from now onward (including current)
        let now = Date()
        let calendar = Calendar.current
        let appts = items.filter { $0.kind == .appointment }
            .sorted { (a, b) in
                let aStart = calendar.date(bySettingHour: (a.startMinutes ?? 0) / 60, minute: (a.startMinutes ?? 0) % 60, second: 0, of: a.date) ?? a.date
                let bStart = calendar.date(bySettingHour: (b.startMinutes ?? 0) / 60, minute: (b.startMinutes ?? 0) % 60, second: 0, of: b.date) ?? b.date
                return aStart < bStart
            }
            .filter { appt in
                let start = calendar.date(bySettingHour: (appt.startMinutes ?? 0) / 60, minute: (appt.startMinutes ?? 0) % 60, second: 0, of: appt.date) ?? appt.date
                let end = appt.endMinutes.flatMap { em in calendar.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: appt.date) } ?? start
                let grace: TimeInterval = 5 * 60
                return end >= now || now < start.addingTimeInterval(grace)
            }
        let snapshots = appts.map { item in
            NextAppointmentSnapshot(date: item.date, startMinutes: item.startMinutes, endMinutes: item.endMinutes, durationMinutes: item.durationMinutes, title: item.title, location: item.location)
        }
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: upcomingKey)
            if let url = listFileURL {
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    #if DEBUG
                    print("[NextAppointmentSharedStore] Failed to write list file: \(error)")
                    #endif
                }
            }
        }
    }
    
    static func loadList() -> [NextAppointmentSnapshot] {
        // Prefer file-based list for robustness
        if let url = listFileURL, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([NextAppointmentSnapshot].self, from: data) {
            return decoded
        }
        // Fallback to UserDefaults
        guard let defaults = defaults, let data = defaults.data(forKey: upcomingKey) else {
            #if DEBUG
            print("[NextAppointmentSharedStore] No list data available in file or defaults.")
            #endif
            return []
        }
        return (try? JSONDecoder().decode([NextAppointmentSnapshot].self, from: data)) ?? []
    }
}
