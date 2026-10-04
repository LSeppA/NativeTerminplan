import WidgetKit
import SwiftUI
import os

struct AppointmentEntry: TimelineEntry {
    let date: Date
    let title: String
    let subtitle: String
    let startTimeText: String?
    let endTimeText: String?
    let concurrentCount: Int?
}

struct AppointmentProvider: TimelineProvider {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "NextAppointmentWidget")

    private func timeText(from minutes: Int?) -> String? {
        guard let m = minutes else { return nil }
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private func endTimeText(from minutes: Int?, startMinutes: Int?, duration: Int?) -> String? {
        if let em = minutes { return timeText(from: em) }
        if let start = startMinutes, let dur = duration { return timeText(from: start + dur) }
        return nil
    }

    private func subtitle(title: String, location: String) -> String {
        [title, location.isEmpty ? nil : location].compactMap { $0 }.joined(separator: " • ")
    }

    private func startDate(for snap: NextAppointmentSnapshot, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: (snap.startMinutes ?? 0) / 60,
                      minute: (snap.startMinutes ?? 0) % 60,
                      second: 0,
                      of: snap.date) ?? snap.date
    }

    private func endDate(for snap: NextAppointmentSnapshot, calendar: Calendar, start: Date) -> Date {
        return snap.endMinutes
            .flatMap { em in calendar.date(bySettingHour: em / 60, minute: em % 60, second: 0, of: snap.date) }
            ?? (snap.durationMinutes.flatMap { calendar.date(byAdding: .minute, value: $0, to: start) } ?? start)
    }

    private func timeText(for snap: NextAppointmentSnapshot) -> String? {
        timeText(from: snap.startMinutes)
    }

    private func subtitle(for snap: NextAppointmentSnapshot) -> String {
        subtitle(title: snap.title, location: snap.location)
    }

    private func endTimeText(for snap: NextAppointmentSnapshot) -> String? {
        endTimeText(from: snap.endMinutes, startMinutes: snap.startMinutes, duration: nil)
    }

    private func concurrentCount(for base: NextAppointmentSnapshot, in list: [NextAppointmentSnapshot]) -> Int {
        guard let s = base.startMinutes else { return 1 }
        return list.filter { $0.date == base.date && $0.startMinutes == s }.count
    }

    private func firstWithStart(in array: ArraySlice<NextAppointmentSnapshot>) -> NextAppointmentSnapshot? {
        return array.first(where: { $0.startMinutes != nil })
    }
    
    private func earliestUpcomingPreferringSecond(startingFrom index: Int, in list: [NextAppointmentSnapshot]) -> NextAppointmentSnapshot? {
        guard index < list.count else { return nil }
        let base = list[index]
        let sameDay = list[index...].filter { $0.date == base.date }
        guard let first = firstWithStart(in: sameDay[sameDay.startIndex...]) else { return nil }
        guard let sm = first.startMinutes else { return first }
        let sameStart = sameDay.filter { $0.startMinutes == sm }
        if sameStart.count >= 2 {
            return sameStart[1]
        }
        return first
    }

    private func logAppend(_ label: String, entry: AppointmentEntry) {
        let null = "nil"
        AppointmentProvider.logger.info("getTimeline: appended \(label) entry at \(entry.date) title=\(entry.title) subtitle=\(entry.subtitle) startTime=\(entry.startTimeText ?? null) endTime=\(entry.endTimeText ?? null)")
    }

    func placeholder(in context: Context) -> AppointmentEntry {
        AppointmentProvider.logger.info("Widget placeholder requested")
        return AppointmentEntry(date: Date(), title: "Als Nächstes", subtitle: "12:30 • Therapie", startTimeText: "12:30", endTimeText: nil, concurrentCount: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (AppointmentEntry) -> Void) {
        AppointmentProvider.logger.info("Widget snapshot requested (isPreview=\(context.isPreview))")
        completion(entryForCurrentData())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AppointmentEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        var entries: [AppointmentEntry] = []

        AppointmentProvider.logger.info("getTimeline: building timeline at \(now)")

        // Default next refresh as a fallback
        var nextRefresh = now.addingTimeInterval(15 * 60)

        // Prefer the saved list for precise scheduling
        let list = NextAppointmentSharedStore.loadList()
        AppointmentProvider.logger.info("getTimeline: loaded list count=\(list.count)")

        if !list.isEmpty {
            // Find the first appointment whose end is in the future (current or next)
            var currentIndex: Int? = nil
            for (idx, snap) in list.enumerated() {
                let start = startDate(for: snap, calendar: calendar)
                let end = endDate(for: snap, calendar: calendar, start: start)
                if end >= now { currentIndex = idx; break }
            }

            if let idx = currentIndex {
                AppointmentProvider.logger.info("getTimeline: currentIndex=\(idx)")
                let current = list[idx]
                let currentStart = startDate(for: current, calendar: calendar)
                let currentEnd = endDate(for: current, calendar: calendar, start: currentStart)
                let duration = currentEnd.timeIntervalSince(currentStart)
                let fiveAfter = currentStart.addingTimeInterval(5 * 60)
                let nextSnap = (idx + 1 < list.count) ? firstWithStart(in: list[(idx+1)...]) : nil

                let isAtOrAfterEnd = now >= currentEnd
                // Determine which to show now with stricter pre-start rule: before the current start, always show the earliest upcoming start on that day
                let showNow: NextAppointmentSnapshot
                if isAtOrAfterEnd, let nextSnap {
                    showNow = nextSnap
                } else if now < currentStart {
                    // We are before the first upcoming start; prefer the second if multiple share the earliest start
                    let preferred = earliestUpcomingPreferringSecond(startingFrom: idx, in: list) ?? current
                    showNow = preferred
                } else if duration < 5 * 60 || now >= fiveAfter, let nextSnap {
                    showNow = nextSnap
                } else {
                    showNow = current
                }
                let nowTimeText = timeText(for: showNow)
                let nowEndTimeText = endTimeText(from: showNow.endMinutes, startMinutes: showNow.startMinutes, duration: nil)
                let nowSubtitle = subtitle(for: showNow)
                // Title: show "Jetzt" during the first 5 minutes of the current appointment; otherwise show next
                let isShowingCurrent = (showNow.date == current.date && showNow.startMinutes == current.startMinutes && showNow.endMinutes == current.endMinutes)
                let isWithinFirstFive = now >= currentStart && now <= min(fiveAfter, currentEnd)
                let titleNow = (isShowingCurrent && isWithinFirstFive) ? "Jetzt" : "Als Nächstes"
                let ccNow = concurrentCount(for: showNow, in: list)
                let badgeNow = ccNow > 1 ? ccNow : nil
                entries.append(AppointmentEntry(date: now, title: titleNow, subtitle: nowSubtitle, startTimeText: nowTimeText, endTimeText: nowEndTimeText, concurrentCount: badgeNow))
                logAppend("NOW", entry: entries.last!)

                // Entry at the exact start to flip to "Jetzt" if timeline is built before start
                if currentStart > now {
                    let tStart = timeText(for: current)
                    let eStart = endTimeText(from: current.endMinutes, startMinutes: current.startMinutes, duration: nil)
                    let sStart = subtitle(for: current)
                    let ccStart = concurrentCount(for: current, in: list)
                    let badgeStart = ccStart > 1 ? ccStart : nil
                    // Ensure title is "Jetzt" here for the start entry
                    entries.append(AppointmentEntry(date: currentStart, title: "Jetzt", subtitle: sStart, startTimeText: tStart, endTimeText: eStart, concurrentCount: badgeStart))
                    logAppend("START", entry: entries.last!)
                    nextRefresh = min(nextRefresh, currentStart)

                    // Post-start small refresh (+7s) to stabilize UI
                    let postStart = currentStart.addingTimeInterval(7)
                    if postStart > now {
                        let tPS = timeText(for: current)
                        let ePS = endTimeText(from: current.endMinutes, startMinutes: current.startMinutes, duration: nil)
                        let sPS = subtitle(for: current)
                        let ccPS = concurrentCount(for: current, in: list)
                        let badgePS = ccPS > 1 ? ccPS : nil
                        entries.append(AppointmentEntry(date: postStart, title: "Jetzt", subtitle: sPS, startTimeText: tPS, endTimeText: ePS, concurrentCount: badgePS))
                        logAppend("POST-START", entry: entries.last!)
                        nextRefresh = min(nextRefresh, postStart)
                    }

                    if let nextSnap {
                        let nextStart = startDate(for: nextSnap, calendar: calendar)
                        if nextStart > now {
                            let tNS = timeText(for: nextSnap)
                            let eNS = endTimeText(from: nextSnap.endMinutes, startMinutes: nextSnap.startMinutes, duration: nil)
                            let sNS = subtitle(for: nextSnap)
                            let ccNS = concurrentCount(for: nextSnap, in: list)
                            let badgeNS = ccNS > 1 ? ccNS : nil
                            // Ensure this next start entry also has title "Jetzt" at exact start
                            entries.append(AppointmentEntry(date: nextStart, title: "Jetzt", subtitle: sNS, startTimeText: tNS, endTimeText: eNS, concurrentCount: badgeNS))
                            logAppend("NEXT-START", entry: entries.last!)
                            nextRefresh = min(nextRefresh, nextStart)
                        }
                    }
                }

                // Entry at five minutes after current start to switch to next (if available)
                if duration >= 5 * 60, fiveAfter > now {
                    let showAtFive = nextSnap ?? current
                    let t = timeText(for: showAtFive)
                    let e = endTimeText(from: showAtFive.endMinutes, startMinutes: showAtFive.startMinutes, duration: nil)
                    let s = subtitle(for: showAtFive)
                    let ccFive = concurrentCount(for: showAtFive, in: list)
                    let badgeFive = ccFive > 1 ? ccFive : nil
                    entries.append(AppointmentEntry(date: fiveAfter, title: "Als Nächstes", subtitle: s, startTimeText: t, endTimeText: e, concurrentCount: badgeFive))
                    logAppend("", entry: entries.last!)
                    nextRefresh = min(nextRefresh, fiveAfter)
                }

                // Entry at (END + 1min5s) to switch to next (if available)
                if currentEnd > now, let nextSnap {
                    let tNext = timeText(for: nextSnap)
                    let eNext = endTimeText(from: nextSnap.endMinutes, startMinutes: nextSnap.startMinutes, duration: nil)
                    let sNext = subtitle(for: nextSnap)
                    let ccEnd = concurrentCount(for: nextSnap, in: list)
                    let badgeEnd = ccEnd > 1 ? ccEnd : nil
                    let delayedEnd = currentEnd.addingTimeInterval(65)
                    entries.append(AppointmentEntry(date: delayedEnd, title: "Als Nächstes", subtitle: sNext, startTimeText: tNext, endTimeText: eNext, concurrentCount: badgeEnd))
                    logAppend("END+1m5s", entry: entries.last!)
                    nextRefresh = min(nextRefresh, delayedEnd)
                }

                // If fiveAfter already passed or the appointment is shorter than 5 minutes, schedule at the next appointment start
                if let nextSnap {
                    let nextStart = startDate(for: nextSnap, calendar: calendar)
                    if nextStart > now {
                        let t = timeText(for: nextSnap)
                        let e = endTimeText(from: nextSnap.endMinutes, startMinutes: nextSnap.startMinutes, duration: nil)
                        let s = subtitle(for: nextSnap)
                        let ccNext = concurrentCount(for: nextSnap, in: list)
                        let badgeNext = ccNext > 1 ? ccNext : nil
                        // Add start entry for next appointment with title "Jetzt"
                        entries.append(AppointmentEntry(date: nextStart, title: "Jetzt", subtitle: s, startTimeText: t, endTimeText: e, concurrentCount: badgeNext))
                        logAppend("", entry: entries.last!)
                        nextRefresh = min(nextRefresh, nextStart)
                    }
                }

                // Add up to two more future appointment start entries for robustness
                if list.count > idx + 2 {
                    for j in (idx + 2)..<min(list.count, idx + 5) {
                        let snap = list[j]
                        let start = startDate(for: snap, calendar: calendar)
                        if start > now {
                            let t = timeText(for: snap)
                            let e = endTimeText(from: snap.endMinutes, startMinutes: snap.startMinutes, duration: nil)
                            let s = subtitle(for: snap)
                            let ccFut = concurrentCount(for: snap, in: list)
                            let badgeFut = ccFut > 1 ? ccFut : nil
                            entries.append(AppointmentEntry(date: start, title: "Als Nächstes", subtitle: s, startTimeText: t, endTimeText: e, concurrentCount: badgeFut))
                            logAppend("", entry: entries.last!)
                            nextRefresh = min(nextRefresh, start)
                        }
                    }
                }
            } else {
                // No current; schedule at the start of the next upcoming appointment if any
                if let first = (list.first(where: { $0.startMinutes != nil }) ?? list.first) {
                    let firstStart = startDate(for: first, calendar: calendar)
                    // Entry for now shows the next upcoming
                    let tNow = timeText(for: first)
                    let eNow = endTimeText(from: first.endMinutes, startMinutes: first.startMinutes, duration: nil)
                    let sNow = subtitle(for: first)
                    let ccNow = concurrentCount(for: first, in: list)
                    let badgeNow = ccNow > 1 ? ccNow : nil
                    entries.append(AppointmentEntry(date: now, title: "Als Nächstes", subtitle: sNow, startTimeText: tNow, endTimeText: eNow, concurrentCount: badgeNow))
                    logAppend("", entry: entries.last!)

                    // Entry at next START to flip to "Jetzt"
                    if firstStart > now {
                        let tStart = timeText(for: first)
                        let eStart = endTimeText(from: first.endMinutes, startMinutes: first.startMinutes, duration: nil)
                        let sStart = subtitle(for: first)
                        let ccStart = concurrentCount(for: first, in: list)
                        let badgeStart = ccStart > 1 ? ccStart : nil
                        entries.append(AppointmentEntry(date: firstStart, title: "Jetzt", subtitle: sStart, startTimeText: tStart, endTimeText: eStart, concurrentCount: badgeStart))
                        logAppend("START", entry: entries.last!)
                        nextRefresh = min(nextRefresh, firstStart)

                        // Post-start small refresh (+7s)
                        let postStart = firstStart.addingTimeInterval(7)
                        let ccPS = concurrentCount(for: first, in: list)
                        let badgePS = ccPS > 1 ? ccPS : nil
                        entries.append(AppointmentEntry(date: postStart, title: "Jetzt", subtitle: sStart, startTimeText: tStart, endTimeText: eStart, concurrentCount: badgePS))
                        logAppend("POST-START", entry: entries.last!)
                        nextRefresh = min(nextRefresh, postStart)
                    }

                    // Entry 5 minutes after the next start to switch to the one after, if available
                    let fiveAfterFirst = firstStart.addingTimeInterval(5 * 60)
                    if list.count > 1 {
                        let second = list[1]
                        let t = timeText(for: second)
                        let e = endTimeText(from: second.endMinutes, startMinutes: second.startMinutes, duration: nil)
                        let s = subtitle(for: second)
                        let fire = max(fiveAfterFirst, now.addingTimeInterval(1))
                        let ccFive = concurrentCount(for: second, in: list)
                        let badgeFive = ccFive > 1 ? ccFive : nil
                        entries.append(AppointmentEntry(date: fire, title: "Als Nächstes", subtitle: s, startTimeText: t, endTimeText: e, concurrentCount: badgeFive))
                        logAppend("", entry: entries.last!)
                        nextRefresh = min(nextRefresh, fire)
                    } else {
                        nextRefresh = min(nextRefresh, firstStart)
                    }
                }
            }
        } else {
            // Fallback to single snapshot and default refresh
            let entry = entryForCurrentData()
            entries.append(entry)
            logAppend("fallback", entry: entries.last!)
        }

        // Ensure we always provide at least one entry
        if entries.isEmpty {
            entries.append(entryForCurrentData())
            logAppend("fallback", entry: entries.last!)
        }

        // Sort entries by date and build timeline; ensure nextRefresh is in the future
        entries.sort { $0.date < $1.date }
        nextRefresh = max(nextRefresh, now.addingTimeInterval(1))
        AppointmentProvider.logger.info("getTimeline: entries=\(entries.count), nextRefresh=\(nextRefresh)")
        let timeline = Timeline(entries: entries, policy: .after(nextRefresh))
        completion(timeline)
    }

    private func nextRefreshDate(from startTimeText: String, on referenceDate: Date) -> Date? {
        let parts = startTimeText.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let cal = Calendar.current
        let start = cal.date(bySettingHour: h, minute: m, second: 0, of: referenceDate)
        return start?.addingTimeInterval(5 * 60)
    }

    private func entryForCurrentData() -> AppointmentEntry {
        AppointmentProvider.logger.info("entryForCurrentData requested")
        let now = Date()
        let calendar = Calendar.current

        // Prefer the list for better decision making (current vs next)
        let list = NextAppointmentSharedStore.loadList()
        if !list.isEmpty {
            // Find the first appointment whose end is in the future (current or next)
            var indexToShow: Int? = nil
            for (idx, snap) in list.enumerated() {
                let start = startDate(for: snap, calendar: calendar)
                let end = endDate(for: snap, calendar: calendar, start: start)
                if end >= now { indexToShow = idx; break }
            }

            if let idx = indexToShow {
                let snap = list[idx]
                let start = startDate(for: snap, calendar: calendar)
                let fiveAfter = start.addingTimeInterval(5 * 60)
                let end = endDate(for: snap, calendar: calendar, start: start)
                
                // Before start: if multiple appointments share the same earliest start, prefer the second by insertion order
                if now < start, idx + 1 < list.count {
                    let candidate = list[idx + 1]
                    if candidate.date == snap.date && candidate.startMinutes == snap.startMinutes {
                        let timeText = timeText(for: candidate)
                        let endText = endTimeText(from: candidate.endMinutes, startMinutes: candidate.startMinutes, duration: nil)
                        let subtitle = subtitle(for: candidate)
                        let cc = concurrentCount(for: candidate, in: list)
                        return AppointmentEntry(date: now, title: "Als Nächstes", subtitle: subtitle, startTimeText: timeText, endTimeText: endText, concurrentCount: (cc > 1 ? cc : nil))
                    }
                }
                
                if now >= end, idx + 1 < list.count {
                    let next = list[idx + 1]
                    let timeText = timeText(for: next)
                    let endText = endTimeText(from: next.endMinutes, startMinutes: next.startMinutes, duration: nil)
                    let subtitle = subtitle(for: next)
                    let cc = concurrentCount(for: next, in: list)
                    return AppointmentEntry(date: now, title: "Als Nächstes", subtitle: subtitle, startTimeText: timeText, endTimeText: endText, concurrentCount: (cc > 1 ? cc : nil))
                } else if now >= fiveAfter, idx + 1 < list.count {
                    AppointmentProvider.logger.info("entryForCurrentData: returning NEXT appointment snapshot")
                    let next = list[idx + 1]
                    let timeText = timeText(for: next)
                    let endText = endTimeText(from: next.endMinutes, startMinutes: next.startMinutes, duration: nil)
                    let subtitle = subtitle(for: next)
                    let cc = concurrentCount(for: next, in: list)
                    return AppointmentEntry(date: now, title: "Als Nächstes", subtitle: subtitle, startTimeText: timeText, endTimeText: endText, concurrentCount: (cc > 1 ? cc : nil))
                } else {
                    AppointmentProvider.logger.info("entryForCurrentData: returning CURRENT/NEXT snapshot")
                    // Show the current (or immediate next) appointment
                    let timeText = timeText(for: snap)
                    let endText = endTimeText(from: snap.endMinutes, startMinutes: snap.startMinutes, duration: nil)
                    let subtitle = subtitle(for: snap)
                    let cc = concurrentCount(for: snap, in: list)
                    return AppointmentEntry(date: now, title: "Als Nächstes", subtitle: subtitle, startTimeText: timeText, endTimeText: endText, concurrentCount: (cc > 1 ? cc : nil))
                }
            }
        }

        // Fallback to single snapshot if list isn't available
        if let snap = NextAppointmentSharedStore.load() {
            #if DEBUG
            print("[Widget] Loaded snapshot: date=\(snap.date), start=\(String(describing: snap.startMinutes)), end=\(String(describing: snap.endMinutes)), title=\(snap.title), location=\(snap.location)")
            #endif
            let timeText: String? = timeText(from: snap.startMinutes)
            let endText = endTimeText(from: snap.endMinutes, startMinutes: snap.startMinutes, duration: nil)
            let subtitle = subtitle(title: snap.title, location: snap.location)
            let calendar = Calendar.current
            let start = calendar.date(bySettingHour: (snap.startMinutes ?? 0) / 60, minute: (snap.startMinutes ?? 0) % 60, second: 0, of: snap.date) ?? snap.date
            let title = (now >= start &&
                         now <= start.addingTimeInterval(5 * 60)) ? "Jetzt" : "Als Nächstes"
            return AppointmentEntry(date: now, title: title, subtitle: subtitle, startTimeText: timeText, endTimeText: endText, concurrentCount: nil)
        }

        AppointmentProvider.logger.info("entryForCurrentData: fallback snapshot")
        #if DEBUG
        print("[Widget] No snapshot available at key \(SharedConstants.nextAppointmentKey)")
        #endif
        return AppointmentEntry(
            date: now,
            title: "Als Nächstes",
            subtitle: "Noch keine Daten",
            startTimeText: nil,
            endTimeText: nil,
            concurrentCount: nil
        )
    }
}

struct NextAppointmentWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: AppointmentProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let t = entry.startTimeText {
                        Text(t)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(entry.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let c = entry.concurrentCount, c > 1 {
                        ZStack {
                            Circle().fill(Color.red)
                            Text("\(c)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("\(c) gleichzeitige Termine")
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Text(entry.subtitle)
                    .font(.headline)
                    .lineLimit(3)
            }
            .padding()

        case .systemMedium:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let t = entry.startTimeText {
                            Text(t)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Text(entry.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let c = entry.concurrentCount, c > 1 {
                            ZStack {
                                Circle().fill(Color.red)
                                Text("\(c)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 16, height: 16)
                            .accessibilityLabel("\(c) gleichzeitige Termine")
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                    Text(entry.subtitle)
                        .font(.headline)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding()

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let t = entry.startTimeText {
                        Text(t)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(entry.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Text(entry.subtitle)
                    .font(.caption)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .accessoryInline:
            Text("\(entry.title): \(entry.subtitle)")
                .lineLimit(1)

        case .accessoryCircular:
            ZStack {
                VStack(spacing: 1) {
                    Text(entry.title == "Jetzt" ? "J" : "N")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    if let t = entry.startTimeText {
                        Text(t).font(.system(size: 10, weight: .semibold))
                    } else {
                        Image(systemName: "calendar").font(.system(size: 12))
                    }
                }
            }
            .accessibilityLabel("\(entry.title): \(entry.subtitle)")

        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.caption).foregroundStyle(.secondary)
                Text(entry.subtitle).font(.headline).lineLimit(2)
            }
            .padding()
        }
    }
}

struct NextAppointmentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextAppointmentWidget", provider: AppointmentProvider()) { entry in
            if #available(iOS 17.0, *) {
                NextAppointmentWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                NextAppointmentWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("Nächster Termin")
        .description("Zeigt den aktuellen oder nächsten Termin.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

#if DEBUG
#Preview(as: .systemSmall) {
    NextAppointmentWidget()
} timeline: {
    AppointmentEntry(date: .now, title: "Als Nächstes", subtitle: "12:30 • Therapie • Raum 2", startTimeText: "12:30", endTimeText: nil, concurrentCount: nil)
}
#endif
