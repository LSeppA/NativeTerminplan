import Foundation
import os
import WidgetKit

struct AppointmentTimelineBuilder {
    private let calendar: Calendar
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "AppointmentTimelineBuilder")

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func placeholderEntry(date: Date = Date()) -> AppointmentEntry {
        AppointmentEntry(date: date, title: "Demnächst", subtitle: "12:30 • Therapie", startTimeText: "12:30", endTimeText: nil, concurrentCount: nil)
    }

    func snapshotEntry(now: Date = Date()) -> AppointmentEntry {
        let snapshots = activeSnapshots(now: now)
        return displayEntry(for: now, snapshots: snapshots) ?? emptyEntry(date: now)
    }

    func timeline(now: Date = Date()) -> Timeline<AppointmentEntry> {
        let snapshots = activeSnapshots(now: now)
        logger.info("Widget timeline requested at \(now), active snapshots=\(snapshots.count)")

        var entries = timelineEntries(from: snapshots, now: now)
        if entries.isEmpty {
            entries = [emptyEntry(date: now)]
        }
        entries.sort { $0.date < $1.date }

        let reloadDate = entries.map(\.date).filter { $0 > now }.min() ?? now.addingTimeInterval(15 * 60)
        return Timeline(entries: entries, policy: .after(max(reloadDate, now.addingTimeInterval(1))))
    }

    private func activeSnapshots(now: Date) -> [NextAppointmentSnapshot] {
        NextAppointmentSharedStore.loadList()
            .filter { endDate(for: $0) > now || startDate(for: $0) > now }
            .sorted { startDate(for: $0) < startDate(for: $1) }
    }

    private func timelineEntries(from snapshots: [NextAppointmentSnapshot], now: Date) -> [AppointmentEntry] {
        guard !snapshots.isEmpty else { return [] }

        var entries: [AppointmentEntry] = []
        if let current = displayEntry(for: now, snapshots: snapshots) {
            entries.append(current)
        }

        for index in snapshots.indices {
            let snapshot = snapshots[index]
            let start = startDate(for: snapshot)
            let end = endDate(for: snapshot)
            let next = nextSnapshot(after: index, in: snapshots)

            if start > now {
                entries.append(entry(from: snapshot, date: start, title: "Jetzt", snapshots: snapshots))
            }

            if let next {
                let switchDate = nextSwitchDate(start: start, end: end)
                if switchDate > now {
                    entries.append(entry(from: next, date: switchDate, title: "Demnächst", snapshots: snapshots))
                }
            } else if end > now {
                entries.append(emptyEntry(date: end.addingTimeInterval(1)))
            }
        }

        return deduplicated(entries)
    }

    private func displayEntry(for date: Date, snapshots: [NextAppointmentSnapshot]) -> AppointmentEntry? {
        guard let index = snapshots.firstIndex(where: { endDate(for: $0) > date || startDate(for: $0) > date }) else {
            return nil
        }

        let snapshot = snapshots[index]
        let start = startDate(for: snapshot)
        let end = endDate(for: snapshot)

        if date < start {
            return entry(from: snapshot, date: date, title: "Demnächst", snapshots: snapshots)
        }

        if date < end {
            if let next = nextSnapshot(after: index, in: snapshots),
               date >= nextSwitchDate(start: start, end: end) {
                return entry(from: next, date: date, title: "Demnächst", snapshots: snapshots)
            }
            return entry(from: snapshot, date: date, title: "Jetzt", snapshots: snapshots)
        }

        if let next = nextSnapshot(after: index, in: snapshots) {
            return entry(from: next, date: date, title: "Demnächst", snapshots: snapshots)
        }
        return nil
    }

    private func nextSnapshot(after index: Int, in snapshots: [NextAppointmentSnapshot]) -> NextAppointmentSnapshot? {
        guard index + 1 < snapshots.count else { return nil }
        return snapshots[(index + 1)...].first { $0.startMinutes != nil }
    }

    private func nextSwitchDate(start: Date, end: Date) -> Date {
        max(start.addingTimeInterval(1), end.addingTimeInterval(-5 * 60))
    }

    private func entry(from snapshot: NextAppointmentSnapshot, date: Date, title: String, snapshots: [NextAppointmentSnapshot]) -> AppointmentEntry {
        let count = concurrentCount(for: snapshot, in: snapshots)
        return AppointmentEntry(
            date: date,
            title: title,
            subtitle: subtitle(for: snapshot),
            startTimeText: timeText(from: snapshot.startMinutes),
            endTimeText: endTimeText(for: snapshot),
            concurrentCount: count > 1 ? count : nil
        )
    }

    private func emptyEntry(date: Date) -> AppointmentEntry {
        AppointmentEntry(date: date, title: "Demnächst", subtitle: "Noch keine Daten", startTimeText: nil, endTimeText: nil, concurrentCount: nil)
    }

    private func startDate(for snapshot: NextAppointmentSnapshot) -> Date {
        calendar.date(
            bySettingHour: (snapshot.startMinutes ?? 0) / 60,
            minute: (snapshot.startMinutes ?? 0) % 60,
            second: 0,
            of: snapshot.date
        ) ?? snapshot.date
    }

    private func endDate(for snapshot: NextAppointmentSnapshot) -> Date {
        let start = startDate(for: snapshot)
        if let endMinutes = snapshot.endMinutes {
            return calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: snapshot.date) ?? start
        }
        if let durationMinutes = snapshot.durationMinutes {
            return calendar.date(byAdding: .minute, value: durationMinutes, to: start) ?? start
        }
        return start
    }

    private func timeText(from minutes: Int?) -> String? {
        guard let minutes else { return nil }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func endTimeText(for snapshot: NextAppointmentSnapshot) -> String? {
        if let endMinutes = snapshot.endMinutes { return timeText(from: endMinutes) }
        if let startMinutes = snapshot.startMinutes, let duration = snapshot.durationMinutes {
            return timeText(from: startMinutes + duration)
        }
        return nil
    }

    private func subtitle(for snapshot: NextAppointmentSnapshot) -> String {
        [snapshot.title, snapshot.location.isEmpty ? nil : snapshot.location].compactMap { $0 }.joined(separator: " • ")
    }

    private func concurrentCount(for base: NextAppointmentSnapshot, in snapshots: [NextAppointmentSnapshot]) -> Int {
        guard let startMinutes = base.startMinutes else { return 1 }
        return snapshots.filter { $0.date == base.date && $0.startMinutes == startMinutes }.count
    }

    private func deduplicated(_ entries: [AppointmentEntry]) -> [AppointmentEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            let key = "\(entry.date.timeIntervalSince1970)-\(entry.title)-\(entry.subtitle)"
            return seen.insert(key).inserted
        }
    }
}
