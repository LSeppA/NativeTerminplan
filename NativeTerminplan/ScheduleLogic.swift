import Foundation

struct ScheduleImportResult {
    let trimmedItems: [ScheduleItem]
    let importedItems: [ScheduleItem]
    let mergedItems: [ScheduleItem]
    let replacedAppointments: [ScheduleItem]
    let skippedPastAppointments: [ScheduleItem]
}

enum ScheduleLogic {
    private static let footerMarkers = ["sehr verehrte", "sehr geehrte"]
    private static let currentGrace: TimeInterval = 5 * 60

    static func sorted(_ items: [ScheduleItem], calendar: Calendar = .current) -> [ScheduleItem] {
        items.sorted { first, second in
            let firstDay = calendar.startOfDay(for: first.date)
            let secondDay = calendar.startOfDay(for: second.date)
            if firstDay != secondDay { return firstDay < secondDay }
            return (first.startMinutes ?? .max) < (second.startMinutes ?? .max)
        }
    }

    static func groupedDays(from items: [ScheduleItem], calendar: Calendar = .current) -> [ScheduleDay] {
        Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.date) })
            .map { ScheduleDay(date: $0.key, items: sorted($0.value, calendar: calendar)) }
            .sorted { $0.date < $1.date }
    }

    static func appointmentEnd(for item: ScheduleItem, calendar: Calendar = .current) -> Date? {
        item.endDate(calendar: calendar)
    }

    static func isCurrent(_ item: ScheduleItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard item.kind == .appointment, let start = item.startDate(calendar: calendar) else { return false }
        let end = appointmentEnd(for: item, calendar: calendar) ?? start
        return now >= start && now <= end
    }

    static func isPastAppointment(_ item: ScheduleItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard item.kind == .appointment else { return false }
        let start = item.startDate(calendar: calendar) ?? item.date
        let end = appointmentEnd(for: item, calendar: calendar) ?? start
        return end < now
    }

    static func currentAppointment(in items: [ScheduleItem], now: Date = Date(), calendar: Calendar = .current) -> ScheduleItem? {
        sorted(items, calendar: calendar).first { isCurrent($0, now: now, calendar: calendar) }
    }

    static func currentOrNext(from items: [ScheduleItem], now: Date = Date(), calendar: Calendar = .current) -> ScheduleItem? {
        let appointments = sorted(items.filter { $0.kind == .appointment }, calendar: calendar)
        for appointment in appointments {
            let start = appointment.startDate(calendar: calendar) ?? appointment.date
            let end = appointmentEnd(for: appointment, calendar: calendar) ?? start
            if now >= start && now <= end {
                if now.timeIntervalSince(start) <= currentGrace { return appointment }
                continue
            }
            if start > now { return appointment }
        }
        return nil
    }

    static func nextUpcomingStart(in items: [ScheduleItem], after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        sorted(items.filter { $0.kind == .appointment }, calendar: calendar)
            .compactMap { $0.startDate(calendar: calendar) }
            .first { $0 > now }
    }

    static func activeItems(from items: [ScheduleItem], now: Date = Date(), calendar: Calendar = .current) -> [ScheduleItem] {
        items.filter { item in
            guard item.kind == .appointment else { return true }
            return !isPastAppointment(item, now: now, calendar: calendar)
        }
    }

    static func trimFooter(from items: [ScheduleItem]) -> [ScheduleItem] {
        guard let index = items.firstIndex(where: { item in
            let title = item.title.lowercased()
            return footerMarkers.contains { title.contains($0) }
        }) else {
            return items
        }
        return Array(items.prefix(upTo: index))
    }

    static func withPhotoPath(_ photoPath: String?, appliedTo items: [ScheduleItem]) -> [ScheduleItem] {
        guard let photoPath else { return items }
        return items.map { item in
            var copy = item
            if item.kind == .appointment {
                copy.photoFileURL = photoPath
            }
            return copy
        }
    }

    static func mergeImportedItems(_ importedItems: [ScheduleItem], into existingItems: [ScheduleItem], calendar: Calendar = .current) -> [ScheduleItem] {
        let affectedDays = Set(importedItems.map { calendar.startOfDay(for: $0.date) })
        var itemsByDay = Dictionary(grouping: existingItems, by: { calendar.startOfDay(for: $0.date) })
        for day in affectedDays {
            itemsByDay[day] = []
        }

        let importedByDay = Dictionary(grouping: importedItems, by: { calendar.startOfDay(for: $0.date) })
        for (day, items) in importedByDay {
            itemsByDay[day, default: []] = items
        }

        return sorted(itemsByDay.flatMap { $0.value }, calendar: calendar)
    }

    static func appointmentsOnAffectedDays(replacedBy importedItems: [ScheduleItem], in existingItems: [ScheduleItem], calendar: Calendar = .current) -> [ScheduleItem] {
        let affectedDays = Set(importedItems.map { calendar.startOfDay(for: $0.date) })
        return existingItems.filter { item in
            item.kind == .appointment && affectedDays.contains(calendar.startOfDay(for: item.date))
        }
    }

    static func prepareImport(recognizedItems: [ScheduleItem], existingItems: [ScheduleItem], photoPath: String?, now: Date = Date(), calendar: Calendar = .current) -> ScheduleImportResult {
        let trimmedItems = trimFooter(from: recognizedItems)
        let skippedPastAppointments = trimmedItems.filter { isPastAppointment($0, now: now, calendar: calendar) }
        let activeImportedItems = activeItems(from: trimmedItems, now: now, calendar: calendar)
        let importedItems = withPhotoPath(photoPath, appliedTo: activeImportedItems)
        let replacedAppointments = appointmentsOnAffectedDays(replacedBy: importedItems, in: existingItems, calendar: calendar)
        let mergedItems = mergeImportedItems(importedItems, into: existingItems, calendar: calendar)
        return ScheduleImportResult(trimmedItems: trimmedItems, importedItems: importedItems, mergedItems: mergedItems, replacedAppointments: replacedAppointments, skippedPastAppointments: skippedPastAppointments)
    }
}
