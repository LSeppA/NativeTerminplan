import Foundation
import Testing
@testable import Mein_Terminplan

@Suite("ScheduleLogic")
struct ScheduleLogicTests {
    private let calendar = Calendar(identifier: .gregorian)

    @Test func currentOrNextReturnsCurrentWithinFirstFiveMinutes() throws {
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9, minute: 3)))
        let item = appointment(day: day, start: 9 * 60, end: 10 * 60)

        #expect(ScheduleLogic.currentOrNext(from: [item], now: now, calendar: calendar)?.id == item.id)
    }

    @Test func currentOrNextSkipsCurrentAfterGracePeriod() throws {
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9, minute: 10)))
        let current = appointment(day: day, start: 9 * 60, end: 10 * 60, title: "Current")
        let next = appointment(day: day, start: 11 * 60, end: 12 * 60, title: "Next")

        #expect(ScheduleLogic.currentOrNext(from: [current, next], now: now, calendar: calendar)?.id == next.id)
    }

    @Test func prepareImportReplacesOnlyAffectedDays() throws {
        let firstDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let secondDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let existingFirstDay = appointment(day: firstDay, start: 9 * 60, end: 10 * 60, title: "Old")
        let existingSecondDay = appointment(day: secondDay, start: 9 * 60, end: 10 * 60, title: "Keep")
        let importedFirstDay = appointment(day: firstDay, start: 11 * 60, end: 12 * 60, title: "New")

        let result = ScheduleLogic.prepareImport(
            recognizedItems: [importedFirstDay],
            existingItems: [existingFirstDay, existingSecondDay],
            photoPath: "/tmp/photo.jpg",
            now: try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 8))),
            calendar: calendar
        )

        #expect(result.replacedAppointments.map(\.id) == [existingFirstDay.id])
        #expect(result.mergedItems.contains { $0.id == importedFirstDay.id && $0.photoFileURL == "/tmp/photo.jpg" })
        #expect(result.mergedItems.contains { $0.id == existingSecondDay.id })
        #expect(!result.mergedItems.contains { $0.id == existingFirstDay.id })
    }

    @Test func trimFooterRemovesLetterText() throws {
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4)))
        let appointment = appointment(day: day, start: 9 * 60, end: 10 * 60)
        let footer = information(day: day, title: "Sehr geehrte Patientin")

        #expect(ScheduleLogic.trimFooter(from: [appointment, footer]) == [appointment])
    }

    private func appointment(day: Date, start: Int, end: Int, title: String = "Therapie") -> ScheduleItem {
        ScheduleItem(date: day, startMinutes: start, endMinutes: end, durationMinutes: nil, title: title, location: "", note: "", kind: .appointment)
    }

    private func information(day: Date, title: String) -> ScheduleItem {
        ScheduleItem(date: day, startMinutes: nil, endMinutes: nil, durationMinutes: nil, title: title, location: "", note: "", kind: .information)
    }
}
