import Foundation

struct NextAppointmentSnapshot: Codable {
    var date: Date
    var startMinutes: Int?
    var endMinutes: Int?
    var title: String
    var location: String
}

enum NextAppointmentSharedStore {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedConstants.appGroupId) }

    static func save(from item: ScheduleItem?) {
        guard let item else {
            defaults?.removeObject(forKey: SharedConstants.nextAppointmentKey)
            return
        }
        let snapshot = NextAppointmentSnapshot(date: item.date, startMinutes: item.startMinutes, endMinutes: item.endMinutes, title: item.title, location: item.location)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults?.set(data, forKey: SharedConstants.nextAppointmentKey)
            defaults?.synchronize()
        }
    }

    static func load() -> NextAppointmentSnapshot? {
        guard let data = defaults?.data(forKey: SharedConstants.nextAppointmentKey) else { return nil }
        return try? JSONDecoder().decode(NextAppointmentSnapshot.self, from: data)
    }
}
