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
    private let builder = AppointmentTimelineBuilder()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MeinTerminplan", category: "NextAppointmentWidget")

    func placeholder(in context: Context) -> AppointmentEntry {
        AppointmentProvider.logger.info("Widget placeholder requested")
        return builder.placeholderEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (AppointmentEntry) -> Void) {
        AppointmentProvider.logger.info("Widget snapshot requested (isPreview=\(context.isPreview))")
        completion(builder.snapshotEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AppointmentEntry>) -> Void) {
        completion(builder.timeline())
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
                    Text(entry.title == "Jetzt" ? "J" : "D")
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
    AppointmentEntry(date: .now, title: "Demnächst", subtitle: "12:30 • Therapie", startTimeText: "12:30", endTimeText: nil, concurrentCount: nil)
}
#endif
