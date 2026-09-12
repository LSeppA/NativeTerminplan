import Foundation
import UIKit
import Vision

private struct OCRFragment {
    let text: String
    let rect: CGRect
    var centerYFromTop: CGFloat { 1 - rect.midY }
}

private struct OCRRow {
    var fragments: [OCRFragment]
    var y: CGFloat

    var timeColumn: String { text(where: { $0.rect.midX < 0.19 }) }
    var titleColumn: String { text(where: { $0.rect.midX >= 0.19 && $0.rect.midX < 0.55 }) }
    var roomColumn: String { text(where: { $0.rect.midX >= 0.55 }) }
    var allText: String { fragments.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }

    private func text(where predicate: (OCRFragment) -> Bool) -> String {
        fragments.filter(predicate).sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
    }
}

final class OCRService {
    private let calendar = Calendar(identifier: .gregorian)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()

    func recognizeSchedule(in image: UIImage) async throws -> [ScheduleItem] {
        let fragments = try await recognizeText(in: image)
        return parse(rows: makeRows(from: fragments))
    }

    private func recognizeText(in image: UIImage) async throws -> [OCRFragment] {
        guard let cgImage = image.cgImage else { throw OCRFailure.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let fragments = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRFragment? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRFragment(text: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines), rect: observation.boundingBox)
                }
                continuation.resume(returning: fragments)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.012
            request.customWords = ["Mittagessen", "Wochenplan", "Therapiezentrum", "Überwasser", "Sensomotoriktraining", "Bewegungstraining"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func makeRows(from fragments: [OCRFragment]) -> [OCRRow] {
        let sorted = fragments.sorted { lhs, rhs in
            abs(lhs.centerYFromTop - rhs.centerYFromTop) < 0.005 ? lhs.rect.minX < rhs.rect.minX : lhs.centerYFromTop < rhs.centerYFromTop
        }
        var rows: [OCRRow] = []
        for fragment in sorted {
            if let index = rows.indices.last(where: { abs(rows[$0].y - fragment.centerYFromTop) < 0.014 }) {
                rows[index].fragments.append(fragment)
            } else {
                rows.append(OCRRow(fragments: [fragment], y: fragment.centerYFromTop))
            }
        }
        return rows
    }

    private func parse(rows: [OCRRow]) -> [ScheduleItem] {
        var currentDate: Date?
        var result: [ScheduleItem] = []
        var lastAppointmentIndex: Int?

        for row in rows {
            if let date = date(in: row.allText) {
                currentDate = date
                lastAppointmentIndex = nil
                continue
            }
            guard let currentDate else { continue }

            let columns = columns(for: row)
            let time = columns.time
            let title = columns.title
            let room = columns.room

            if let range = timeRange(in: time) {
                let item = ScheduleItem(date: currentDate, startMinutes: range.start, endMinutes: range.end, durationMinutes: nil, title: title.isEmpty ? "Termin" : title, location: room, note: "", kind: .appointment)
                result.append(item)
                lastAppointmentIndex = result.indices.last
                continue
            }

            if let duration = duration(in: time), let index = lastAppointmentIndex {
                result[index].durationMinutes = duration
                if result[index].endMinutes == nil, let start = result[index].startMinutes { result[index].endMinutes = start + duration }
                continue
            }

            // Notes and title continuations have no time but belong to the immediately preceding appointment.
            if let index = lastAppointmentIndex, room.isEmpty, !title.isEmpty,
               title.hasPrefix("(") || title.lowercased().hasPrefix("bitte") || result[index].title.hasSuffix("/") {
                if title.hasPrefix("(") {
                    result[index].title = clean("\(result[index].title) \(title)")
                    continue
                }
                if title.lowercased().hasPrefix("bitte") {
                    result[index].note = clean("\(result[index].note) \(title)")
                    continue
                }
                result[index].title = clean("\(result[index].title) \(title)")
                continue
            }

            // A row without time is a first-class information row, not a discarded appointment.
            if !title.isEmpty || !room.isEmpty {
                result.append(ScheduleItem(date: currentDate, startMinutes: nil, endMinutes: nil, durationMinutes: nil, title: title, location: room, note: "", kind: .information))
                lastAppointmentIndex = nil
            }
        }
        return result
    }

    private func date(in text: String) -> Date? {
        guard let match = text.range(of: #"\d{1,2}\.\d{1,2}\.\d{4}"#, options: .regularExpression) else { return nil }
        return dateFormatter.date(from: String(text[match]))
    }

    /// Vision usually returns distinct observations for each printed column. If a camera image
    /// yields one observation spanning a complete table row, recover its three columns from the
    /// known schedule grammar instead of treating it as a single title.
    private func columns(for row: OCRRow) -> (time: String, title: String, room: String) {
        let normal = (clean(row.timeColumn), clean(row.titleColumn), clean(row.roomColumn))
        let combined = row.fragments.first(where: { $0.rect.width > 0.42 })?.text ?? row.allText
        let hasLeadingTime = combined.range(of: #"^\s*\d{1,2}[:.]\d{2}"#, options: .regularExpression) != nil
        // A time-free row is an information row. Preserve its whole wording rather than
        // guessing where its explanatory text ends and a room begins.
        guard hasLeadingTime else {
            return (normal.0, normal.1.isEmpty ? clean(combined) : normal.1, normal.2)
        }
        let prefixRange = combined.range(of: #"^\s*\d{1,2}[:.]\d{2}(?:\s*[-–—]\s*\d{1,2}[:.]\d{2})?"#, options: .regularExpression)
        let time = prefixRange.map { clean(String(combined[$0])) } ?? ""
        let body = prefixRange.map { clean(String(combined[$0.upperBound...])) } ?? clean(combined)
        let roomAnchors = #"\b(Therapiezentrum|Sportw\.?|Raum\b|Speisesaal|Ambulanz|Ordination|Int\.Bad|Rezeption)"#
        guard let roomStart = body.range(of: roomAnchors, options: [.regularExpression, .caseInsensitive]) else {
            return (time.isEmpty ? normal.0 : time, body.isEmpty ? normal.1 : body, normal.2)
        }
        return (time, clean(String(body[..<roomStart.lowerBound])), clean(String(body[roomStart.lowerBound...])))
    }

    private func timeRange(in text: String) -> (start: Int, end: Int?)? {
        guard let match = text.firstMatch(of: #/(?<sh>\d{1,2})[:.](?<sm>\d{2})(?:\s*[-–—]\s*(?<eh>\d{1,2})[:.](?<em>\d{2}))?/#) else { return nil }
        guard let sh = Int(match.output.sh), let sm = Int(match.output.sm) else { return nil }
        let end = (match.output.eh.flatMap { Int($0) }).flatMap { hour in match.output.em.flatMap { Int($0) }.map { hour * 60 + $0 } }
        return (sh * 60 + sm, end)
    }

    private func duration(in text: String) -> Int? {
        guard let match = text.firstMatch(of: #/(\d{1,3})\s*Minuten?/#), let value = Int(match.output.1) else { return nil }
        return value
    }

    private func clean(_ text: String) -> String { text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum OCRFailure: LocalizedError { case invalidImage; var errorDescription: String? { "Das Bild konnte nicht verarbeitet werden." } }
