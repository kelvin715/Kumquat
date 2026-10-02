import CoreGraphics
import Foundation
import Vision

/// On-device text recognition (Vision), used for image → DOCX and for scanned PDFs.
public enum TextRecognizer {
    public struct Line: Sendable {
        public var text: String
        /// Normalized rect, origin at the top-left (y-down), in 0...1.
        public var box: CGRect
    }

    public static func recognizeLines(in image: CGImage, languages: [String]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = languages.filter { supported.contains($0) }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = wanted.isEmpty
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return Line(text: candidate.string,
                        box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }

    /// Bounding boxes (normalized, y-down) of every recognized word-level text region.
    public static func textRegions(in image: CGImage, languages: [String]) throws -> [CGRect] {
        try recognizeLines(in: image, languages: languages).map(\.box)
    }

    /// Faces, normalized and y-down.
    public static func faceRegions(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map { obs in
            let b = obs.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }

    /// Reading-order paragraphs: lines are sorted top-to-bottom, then joined into paragraphs
    /// where the vertical gap is small.
    public static func paragraphs(from lines: [Line]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let sorted = lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 {
                return a.box.minX < b.box.minX
            }
            return a.box.minY < b.box.minY
        }
        let heights = sorted.map(\.box.height).sorted()
        let typical = heights[heights.count / 2]
        // A line that stops well short of the right margin ends its paragraph
        // (headings, addresses, list items); only full-width lines are wrapped prose.
        let rightEdges = sorted.map(\.box.maxX).sorted()
        let rightMargin = rightEdges[Int(Double(rightEdges.count - 1) * 0.9)]
        let marginSlack = max(0.08, (rightEdges.last! - rightEdges.first!) * 0.15)
        var paragraphs: [String] = []
        var current = ""
        var previous: Line?
        for line in sorted {
            if let prev = previous {
                let sameRow = abs(line.box.midY - prev.box.midY) < typical * 0.5
                let gap = line.box.minY - prev.box.maxY
                let previousWraps = prev.box.maxX >= rightMargin - marginSlack
                if sameRow {
                    current += joiner(current, line.text, separator: "  ")
                } else if gap > typical * 0.9 || !previousWraps {
                    paragraphs.append(current)
                    current = line.text
                } else {
                    current += joiner(current, line.text, separator: " ")
                }
            } else {
                current = line.text
            }
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    /// CJK text is joined without spaces; Latin text with one.
    static func joiner(_ existing: String, _ next: String, separator: String) -> String {
        guard let last = existing.unicodeScalars.last, let first = next.unicodeScalars.first else { return next }
        if isCJK(last) || isCJK(first) { return next }
        if last == "-" { return next }
        return separator + next
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    public static func recognizeText(in image: CGImage, languages: [String]) throws -> [String] {
        paragraphs(from: try recognizeLines(in: image, languages: languages))
    }
}
