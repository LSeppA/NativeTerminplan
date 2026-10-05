import CoreGraphics
import Foundation
import Testing
@testable import Mein_Terminplan

@Suite("OCRService parsing")
struct OCRServiceParsingTests {
    @Test func parsesAppointmentDurationAndInformationRows() throws {
        let service = OCRService()
        let rows = [
            row("04.10.2026", y: 0.1),
            row("09:00 - 09:30 Ultraschall 30 Minuten", y: 0.2),
            row("Wochenplan unterschreiben", y: 0.3)
        ]

        let items = service.parse(rows: rows)

        #expect(items.count == 2)
        #expect(items[0].kind == .appointment)
        #expect(items[0].startMinutes == 9 * 60)
        #expect(items[0].endMinutes == 9 * 60 + 30)
        #expect(items[0].durationMinutes == 30)
        #expect(items[0].note == "bitte Leintuch zur Therapie mitnehmen!")
        #expect(items[1].kind == .information)
        #expect(items[1].title == "Wochenplan unterschreiben")
    }

    @Test func ignoresHeaderRowsBeforeFirstAppointment() {
        let service = OCRService()
        let rows = [
            row("04.10.2026", y: 0.1),
            row("Therapiezentrum Bad Vigaun", y: 0.2),
            row("10:15 Bewegungstraining", y: 0.3)
        ]

        let items = service.parse(rows: rows)

        #expect(items.count == 1)
        #expect(items[0].title == "Bewegungstraining")
    }

    @Test func removesRoomCodesFromRecognizedText() {
        let service = OCRService()
        let rows = [
            row("04.10.2026", y: 0.1),
            row("09:00 - 09:30 Ultraschall (Z0302) 30 Minuten", y: 0.2),
            row("Bitte bei Anmeldung melden (A1234)", y: 0.3)
        ]

        let items = service.parse(rows: rows)

        #expect(items.count == 2)
        #expect(items[0].title == "Ultraschall")
        #expect(items[1].title == "Bitte bei Anmeldung melden")
    }

    @Test func groupsFragmentsIntoVisualRows() {
        let service = OCRService()
        let fragments = [
            fragment("09:00", x: 0.1, y: 0.8),
            fragment("Therapie", x: 0.3, y: 0.805),
            fragment("10:00", x: 0.1, y: 0.7)
        ]

        let rows = service.makeRows(from: fragments)

        #expect(rows.count == 2)
        #expect(rows[0].allText == "09:00 Therapie")
        #expect(rows[1].allText == "10:00")
    }

    @Test func parsesRepresentativeA4PlanOCRLines() {
        let service = OCRService()
        let lines = [
            "Therapiezentrum Bad Vigaun",
            "Wochenplan",
            "04.10.2026",
            "09:00 - 09:30 Ultraschall 30 Minuten",
            "10:15 Bewegungstraining",
            "Wochenplan unterschreiben",
            "05.10.2026",
            "08:30 Massage 25 Min.",
            "Sehr geehrte Patientin"
        ]
        let rows = lines.enumerated().map { index, line in
            row(line, y: CGFloat(index) * 0.05)
        }

        let items = service.parse(rows: rows)
        let trimmed = ScheduleLogic.trimFooter(from: items)

        #expect(trimmed.count == 4)
        #expect(trimmed[0].title == "Ultraschall")
        #expect(trimmed[0].durationMinutes == 30)
        #expect(trimmed[1].title == "Bewegungstraining")
        #expect(trimmed[2].title == "Wochenplan unterschreiben")
        #expect(trimmed[3].title == "Massage")
        #expect(trimmed[3].durationMinutes == 25)
    }

    private func row(_ text: String, y: CGFloat) -> OCRRow {
        OCRRow(fragments: [fragment(text, x: 0.1, y: 1 - y)], y: y)
    }

    private func fragment(_ text: String, x: CGFloat, y: CGFloat) -> OCRFragment {
        OCRFragment(text: text, rect: CGRect(x: x, y: y, width: 0.2, height: 0.02))
    }
}
