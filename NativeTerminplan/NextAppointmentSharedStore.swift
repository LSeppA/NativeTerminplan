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

        let snapshot = NextAppointmentSnapshot(
            date: item.date,
            startMinutes: item.startMinutes,
            endMinutes: item.endMinutes,
            durationMinutes: item.durationMinutes,
            title: item.title,
            location: item.location
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            if let defaults = defaults {
                defaults.set(data, forKey: SharedConstants.nextAppointmentKey)
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
        if let url = snapshotsFileURL,
           let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(NextAppointmentSnapshot.self, from: data) {
            return snap
        }

        guard let defaults = defaults,
              let data = defaults.data(forKey: SharedConstants.nextAppointmentKey) else {
            #if DEBUG
            print("[NextAppointmentSharedStore] No snapshot data available in file or defaults.")
            #endif
            return nil
        }
        return try? JSONDecoder().decode(NextAppointmentSnapshot.self, from: data)
    }

    static func saveList(from items: [ScheduleItem]) {
        let now = Date()
        let snapshots = sortedAppointments(from: items)
            .filter { !isPastAppointment($0, now: now) }
            .map { item in
                NextAppointmentSnapshot(
                    date: item.date,
                    startMinutes: item.startMinutes,
                    endMinutes: item.endMinutes,
                    durationMinutes: item.durationMinutes,
                    title: item.title,
                    location: item.location
                )
            }

        if let data = try? JSONEncoder().encode(snapshots) {
            if let defaults {
                defaults.set(data, forKey: upcomingKey)
            } else {
                #if DEBUG
                print("[NextAppointmentSharedStore] Defaults unavailable; saving list file only.")
                #endif
            }
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
        if let url = listFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([NextAppointmentSnapshot].self, from: data) {
            return decoded
        }

        guard let defaults = defaults,
              let data = defaults.data(forKey: upcomingKey) else {
            #if DEBUG
            print("[NextAppointmentSharedStore] No list data available in file or defaults.")
            #endif
            return []
        }
        return (try? JSONDecoder().decode([NextAppointmentSnapshot].self, from: data)) ?? []
    }

    private static func sortedAppointments(from items: [ScheduleItem], calendar: Calendar = .current) -> [ScheduleItem] {
        items.filter { $0.kind == .appointment }
            .sorted { first, second in
                let firstStart = first.startDate(calendar: calendar) ?? first.date
                let secondStart = second.startDate(calendar: calendar) ?? second.date
                return firstStart < secondStart
            }
    }

    private static func isPastAppointment(_ item: ScheduleItem, now: Date, calendar: Calendar = .current) -> Bool {
        let start = item.startDate(calendar: calendar) ?? item.date
        let end = item.endDate(calendar: calendar) ?? start
        return end < now
    }
}
