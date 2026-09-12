import Foundation

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var days: [ScheduleDay] = []
    private let storageKey = "native-terminplan-v1"

    init() { load() }

    func replace(with items: [ScheduleItem]) {
        let calendar = Calendar.current
        days = Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.date) })
            .map { ScheduleDay(date: $0.key, items: $0.value.sorted { ($0.startMinutes ?? .max) < ($1.startMinutes ?? .max) }) }
            .sorted { $0.date < $1.date }
        persist()
    }

    func clear() {
        days = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ScheduleDay].self, from: data) else { return }
        days = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(days) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
