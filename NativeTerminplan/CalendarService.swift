import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {
    @Published var errorMessage: String?
    private let eventStore = EKEventStore()

    func add(_ item: ScheduleItem) async {
        guard let start = item.startMinutes else { return }
        do {
            if #available(iOS 17.0, *) {
                try await eventStore.requestFullAccessToEvents()
            } else {
                try await eventStore.requestAccess(to: .event)
            }
            let event = EKEvent(eventStore: eventStore)
            event.title = item.title
            event.location = item.location
            event.notes = item.note
            event.startDate = date(item.date, minutes: start)
            event.endDate = date(item.date, minutes: item.endMinutes ?? start + (item.durationMinutes ?? 30))
            event.calendar = eventStore.defaultCalendarForNewEvents
            try eventStore.save(event, span: .thisEvent)
        } catch { errorMessage = error.localizedDescription }
    }

    private func date(_ day: Date, minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
}
