import Foundation

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var days: [ScheduleDay] = []
    private let storageKey = "native-terminplan-v1"

    init() { load() }

    var nextAppointment: ScheduleItem? {
        ScheduleLogic.currentOrNext(from: days.flatMap(\.items))
    }

    func replace(with items: [ScheduleItem]) {
        days = ScheduleLogic.groupedDays(from: items)
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

    /// Expired appointments are removed after their end; time-free information lines remain only
    /// for today and future days.
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
                        return !ScheduleLogic.isPastAppointment(item, now: now, calendar: calendar)
                    } else {
                        return calendar.startOfDay(for: item.date) >= today
                    }
                case .information:
                    return calendar.startOfDay(for: item.date) >= today
                }
            }
            return remaining.isEmpty ? nil : ScheduleDay(date: day.date, items: ScheduleLogic.sorted(remaining, calendar: calendar))
        }
        .sorted { $0.date < $1.date }
        persist()
    }
}

