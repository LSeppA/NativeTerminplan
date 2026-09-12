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

    static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

struct ScheduleDay: Identifiable, Codable, Equatable {
    var id: Date { date }
    var date: Date
    var items: [ScheduleItem]
}
