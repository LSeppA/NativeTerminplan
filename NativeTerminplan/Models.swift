import Foundation

enum ScheduleItemKind: String, Codable {
    case appointment
    case information
}

struct ScheduleItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var startMinutes: Int?
    var endMinutes: Int?
    var durationMinutes: Int?
    var title: String
    var location: String
    var note: String
    var kind: ScheduleItemKind

    var timeText: String {
        guard let startMinutes else { return "" }
        let start = Self.clockText(startMinutes)
        guard let endMinutes else { return start }
        return "\(start) – \(Self.clockText(endMinutes))"
    }

    var durationText: String {
        guard let durationMinutes else { return "" }
        return "\(durationMinutes) Minuten"
    }

    func startDate(calendar: Calendar = .current) -> Date? {
        guard let startMinutes else { return nil }
        return calendar.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: date)
    }

    /// Uses the printed end time first, then the printed duration, otherwise the start time.
    func endDate(calendar: Calendar = .current) -> Date? {
        guard let start = startDate(calendar: calendar) else { return nil }
        if let endMinutes {
            return calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: date)
        }
        if let durationMinutes { return calendar.date(byAdding: .minute, value: durationMinutes, to: start) }
        return start
    }

    static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

struct ScheduleDay: Identifiable, Codable, Equatable {
    var id: Date { date }
    var date: Date
    var items: [ScheduleItem]

    var germanHeading: String {
        Self.germanFormatter.string(from: date).capitalized
    }

    private static let germanFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.dateFormat = "EEEE, dd. MMMM yyyy"
        return formatter
    }()
}

