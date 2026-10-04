import Foundation

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var days: [ScheduleDay] = []
    private let storageKey = "native-terminplan-v1"

    init() { load() }

    var nextAppointment: ScheduleItem? {
        let now = Date()
        return days.flatMap(\.items)
            .filter { $0.kind == .appointment && ($0.startDate() ?? .distantPast) >= now }
            .min { ($0.startDate() ?? .distantFuture) < ($1.startDate() ?? .distantFuture) }
    }

    func replace(with items: [ScheduleItem]) {
        let calendar = Calendar.current
        days = Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.date) })
            .map { ScheduleDay(date: $0.key, items: $0.value.sorted { ($0.startMinutes ?? .max) < ($1.startMinutes ?? .max) }) }
            .sorted { $0.date < $1.date }
        removeExpiredItemsAndPersist()
    }

    func clear() {
        days = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ScheduleDay].self, from: data) else { return }
        days = decoded
        removeExpiredItemsAndPersist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Appointments stay visible for 15 minutes after their end. Afterwards they are removed from
    /// the on-device store; time-free information lines remain only for today and future days.
    private func removeExpiredItemsAndPersist() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        days = days.compactMap { day in
            let remaining = day.items.filter { item in
                switch item.kind {
                case .appointment:
                    let hasExplicitEnd = (item.endMinutes != nil) || (item.durationMinutes != nil)
                    if hasExplicitEnd {
                        // Keep if end is in the future or now
                        return (item.endDate(calendar: calendar) ?? item.date) >= now
                    } else {
                        // No explicit end: keep for today; remove only if the day is in the past
                        return calendar.startOfDay(for: item.date) >= today
                    }
                case .information:
                    // Keep information lines only for today and future days
                    return calendar.startOfDay(for: item.date) >= today
                }
            }
            return remaining.isEmpty ? nil : ScheduleDay(date: day.date, items: remaining)
        }
        .sorted { $0.date < $1.date }
        persist()
    }
}

