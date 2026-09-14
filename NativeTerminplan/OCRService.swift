import CoreImage
import Foundation
import UIKit
@preconcurrency import Vision

private struct OCRFragment {
    let text: String
    let rect: CGRect
    var centerYFromTop: CGFloat { 1 - rect.midY }
}

private struct OCRRow {
    var fragments: [OCRFragment]
    var y: CGFloat
    var allText: String { fragments.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
}

/// Reads the schedule as visual text lines. Date lines create the day boundaries.
final class OCRService {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter
    }()
    private let ciContext = CIContext()

    func recognizeSchedule(in source: UIImage) async throws -> [ScheduleItem] {
        let image = source.normalized()
        let corrected = await perspectiveCorrect(image)

        // No fixed columns: one OCR line is one logical schedule line. A date line starts a new day.
        return parse(rows: makeRows(from: try await recognizeFragments(in: corrected)))
    }

    // MARK: - Document preparation

    private func perspectiveCorrect(_ image: UIImage) async -> UIImage {
        guard let cgImage = image.cgImage,
              let rectangle = try? await documentRectangle(in: cgImage) else { return image }
        let extent = CGRect(origin: .zero, size: image.size)
        func point(_ normalized: CGPoint) -> CGPoint { CGPoint(x: normalized.x * extent.width, y: normalized.y * extent.height) }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: point(rectangle.topLeft)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: point(rectangle.topRight)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: point(rectangle.bottomLeft)), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: point(rectangle.bottomRight)), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let outputCG = ciContext.createCGImage(output, from: output.extent) else { return image }
        return UIImage(cgImage: outputCG)
    }

    private func documentRectangle(in cgImage: CGImage) async throws -> VNRectangleObservation {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                guard let rectangle = (request.results as? [VNRectangleObservation])?.first else {
                    continuation.resume(throwing: OCRFailure.noDocument); return
                }
                continuation.resume(returning: rectangle)
            }
            request.minimumConfidence = 0.65
            request.minimumSize = 0.45
            request.maximumObservations = 1
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func recognizeFragments(in image: UIImage) async throws -> [OCRFragment] {
        guard let cgImage = image.cgImage else { throw OCRFailure.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let fragments = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRFragment? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRFragment(text: candidate.string, rect: observation.boundingBox)
                }
                continuation.resume(returning: fragments)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE"]
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.009
            request.customWords = ["Mittagessen", "Wochenplan", "Therapiezentrum", "Überwasser", "Sensomotoriktraining", "Bewegungstraining", "Bad Vigaun"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - Schedule parsing

    private func makeRows(from fragments: [OCRFragment]) -> [OCRRow] {
        let sorted = fragments.sorted { abs($0.centerYFromTop - $1.centerYFromTop) < 0.005 ? $0.rect.minX < $1.rect.minX : $0.centerYFromTop < $1.centerYFromTop }
        var rows: [OCRRow] = []
        for fragment in sorted {
            if let index = rows.indices.last(where: { abs(rows[$0].y - fragment.centerYFromTop) < 0.014 }) { rows[index].fragments.append(fragment) }
            else { rows.append(OCRRow(fragments: [fragment], y: fragment.centerYFromTop)) }
        }
        return rows
    }

    private func parse(rows: [OCRRow]) -> [ScheduleItem] {
        var currentDate: Date?
        var result: [ScheduleItem] = []
        var lastAppointmentIndex: Int?
        for row in rows {
            if let date = date(in: row.allText) { currentDate = date; lastAppointmentIndex = nil; continue }
            guard let currentDate else { continue }
            let line = clean(row.allText)
            if let range = timeRange(in: line) {
                let title = clean(removingTimePrefix(from: line))
                result.append(ScheduleItem(date: currentDate, startMinutes: range.start, endMinutes: range.end, durationMinutes: nil, title: title.isEmpty ? "Termin" : title, location: "", note: "", kind: .appointment))
                lastAppointmentIndex = result.indices.last
            } else if let duration = duration(in: line), let index = lastAppointmentIndex {
                result[index].durationMinutes = duration
                if result[index].endMinutes == nil, let start = result[index].startMinutes { result[index].endMinutes = start + duration }
            } else if let index = lastAppointmentIndex,
                      (line.hasPrefix("(") || line.lowercased().hasPrefix("bitte") || result[index].title.hasSuffix("/")) {
                if line.hasPrefix("(") { result[index].title = clean("\(result[index].title) \(line)") }
                else { result[index].note = clean("\(result[index].note) \(line)") }
            } else if !line.isEmpty {
                // Keep every time-free row, such as "Wochenplan unterschreiben".
                result.append(ScheduleItem(date: currentDate, startMinutes: nil, endMinutes: nil, durationMinutes: nil, title: line, location: "", note: "", kind: .information))
                lastAppointmentIndex = nil
            }
        }
        return result
    }

    private func removingTimePrefix(from text: String) -> String {
        guard let range = text.range(of: #"^\s*\d{1,2}[:.]\d{2}(?:\s*[-–—]\s*\d{1,2}[:.]\d{2})?"#, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    private func date(in text: String) -> Date? {
        guard let range = text.range(of: #"\d{1,2}\.\d{1,2}\.\d{4}"#, options: .regularExpression) else { return nil }
        return dateFormatter.date(from: String(text[range]))
    }
    private func timeRange(in text: String) -> (start: Int, end: Int?)? {
        guard let match = text.firstMatch(of: #/(?<sh>\d{1,2})[:.](?<sm>\d{2})(?:\s*[-–—]\s*(?<eh>\d{1,2})[:.](?<em>\d{2}))?/#), let sh = Int(match.output.sh), let sm = Int(match.output.sm) else { return nil }
        let end = match.output.eh.flatMap { hour in match.output.em.flatMap { minute in Int(hour).flatMap { h in Int(minute).map { h * 60 + $0 } } } }
        return (sh * 60 + sm, end)
    }
    private func duration(in text: String) -> Int? {
        guard let match = text.firstMatch(of: #/(\d{1,3})\s*Minuten?/#), let value = Int(match.output.1) else { return nil }; return value
    }
    private func clean(_ text: String) -> String { text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension UIImage {
    func normalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}

enum OCRFailure: LocalizedError {
    case invalidImage, noDocument
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Das Bild konnte nicht verarbeitet werden."
        case .noDocument: return "Der Wochenplan konnte im Foto nicht abgegrenzt werden."
        }
    }
}

