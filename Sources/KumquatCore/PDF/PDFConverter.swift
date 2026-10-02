import AppKit
import PDFKit

public enum PDFConverter {
    public static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                               progress: ((Double) -> Void)? = nil) async throws -> [URL] {
        switch format {
        case .jpg, .png:
            return try renderPages(input, format: format, options: options, progress: progress)
        case .txt:
            let destination = OutputNaming.convertedURL(for: input, ext: "txt")
            return [try OutputNaming.write(to: destination) { out in
                let text = try extractText(input, options: options)
                try text.write(to: out, atomically: false, encoding: .utf8)
            }]
        case .docx:
            let destination = OutputNaming.convertedURL(for: input, ext: "docx")
            return [try OutputNaming.write(to: destination) { out in
                try DocxWriter.write(try makeDocx(input, options: options), to: out)
            }]
        default:
            throw KumquatError.unsupportedConversion(from: "PDF", to: format.title)
        }
    }

    // MARK: - Images

    /// One page → "Name.jpg" next to the PDF. Several pages → a "Name Pages" folder.
    static func renderPages(_ input: URL, format: OutputFormat, options: ConversionOptions,
                            progress: ((Double) -> Void)?) throws -> [URL] {
        let doc = try PDFRenderer.document(at: input)
        let count = doc.numberOfPages
        guard count > 0 else { throw KumquatError.nothingToDo("\(input.lastPathComponent) has no pages.") }
        let type = ImageIOHelpers.utType(for: format)
        let props: [CFString: Any] = format == .jpg
            ? [kCGImageDestinationLossyCompressionQuality: options.imageQuality,
               kCGImagePropertyDPIWidth: options.pdfDPI, kCGImagePropertyDPIHeight: options.pdfDPI]
            : [kCGImagePropertyDPIWidth: options.pdfDPI, kCGImagePropertyDPIHeight: options.pdfDPI]

        func renderPage(_ number: Int, to url: URL) throws {
            guard let page = doc.page(at: number),
                  let image = PDFRenderer.render(page, dpi: options.pdfDPI)
            else { throw KumquatError.decodeFailed("page \(number) of \(input.lastPathComponent)") }
            try ImageIOHelpers.write(image, to: url, type: type, properties: props)
        }

        if count == 1 {
            let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
            return [try OutputNaming.write(to: destination) { try renderPage(1, to: $0) }]
        }
        let folder = try OutputNaming.makeDirectory(
            input.deletingLastPathComponent().appendingPathComponent("\(OutputNaming.baseName(of: input)) Pages"))
        let digits = String(count).count
        var outputs: [URL] = []
        for number in 1...count {
            try Task.checkCancellation()
            let name = "Page \(String(repeating: "0", count: digits - String(number).count))\(number)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            try renderPage(number, to: url)
            outputs.append(url)
            progress?(Double(number) / Double(count))
        }
        return [folder]
    }

    // MARK: - Text

    /// Embedded text when there is any; pages without text (scans) go through OCR.
    public static func extractText(_ input: URL, options: ConversionOptions) throws -> String {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let cgDoc = try PDFRenderer.document(at: input)
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                pages.append(text)
            } else if let page = cgDoc.page(at: i + 1), let image = PDFRenderer.render(page, dpi: 200) {
                let paragraphs = (try? TextRecognizer.recognizeText(in: image, languages: options.recognitionLanguages)) ?? []
                pages.append(paragraphs.joined(separator: "\n\n"))
            }
        }
        return pages.joined(separator: "\n\n\u{0C}\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - DOCX

    struct StyledLine {
        var runs: [DocxRun]
        var text: String
        var fontSize: Double
        var bold: Bool
    }

    /// Rebuilds paragraphs and headings from the PDF's text layer; scanned pages become
    /// a page image plus recognized text.
    public static func makeDocx(_ input: URL, options: ConversionOptions) throws -> DocxDocument {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let cgDoc = try PDFRenderer.document(at: input)
        var docx = DocxDocument(title: (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? OutputNaming.baseName(of: input))

        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            if i > 0 { docx.appendPageBreak() }
            guard let page = doc.page(at: i) else { continue }
            let lines = styledLines(page)
            if lines.isEmpty {
                guard let cgPage = cgDoc.page(at: i + 1), let image = PDFRenderer.render(cgPage, dpi: 150) else { continue }
                if let jpeg = try? ImageIOHelpers.encode(image, type: .jpeg,
                                                        properties: [kCGImageDestinationLossyCompressionQuality: 0.85]) {
                    docx.append(DocxImage.fitted(data: jpeg, fileExtension: "jpeg", pixelWidth: image.width,
                                                 pixelHeight: image.height, maxWidth: docx.textWidth,
                                                 maxHeight: docx.textHeight * 0.95))
                }
                let paragraphs = (try? TextRecognizer.recognizeText(in: image, languages: options.recognitionLanguages)) ?? []
                for p in paragraphs { docx.append(DocxParagraph(p)) }
                continue
            }
            for paragraph in paragraphs(from: lines) { docx.append(paragraph) }
        }
        return docx
    }

    static func styledLines(_ page: PDFPage) -> [StyledLine] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        var lines: [StyledLine] = []
        let ns = attributed.string as NSString
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
            lineStart = lineEnd
            let text = ns.substring(with: range)
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(StyledLine(runs: [], text: "", fontSize: 0, bold: false))
                continue
            }
            var runs: [DocxRun] = []
            var maxSize = 0.0
            var boldChars = 0
            attributed.enumerateAttributes(in: range) { attrs, r, _ in
                let piece = ns.substring(with: r)
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask) || (font?.fontName.lowercased().contains("bold") ?? false)
                let italic = traits.contains(.italicFontMask)
                let size = Double(font?.pointSize ?? 11)
                maxSize = max(maxSize, size)
                if bold { boldChars += piece.count }
                runs.append(DocxRun(piece, bold: bold, italic: italic))
            }
            lines.append(StyledLine(runs: runs, text: text, fontSize: maxSize, bold: boldChars * 2 > text.count))
        }
        // Drop leading/trailing blank lines.
        while lines.first?.text.isEmpty == true { lines.removeFirst() }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Joins hard-wrapped lines back into paragraphs. A paragraph ends at a blank line, a short
    /// line, a change of font size, or before a bullet / numbered item.
    static func paragraphs(from lines: [StyledLine]) -> [DocxParagraph] {
        let bodySizes = lines.filter { !$0.text.isEmpty }.map(\.fontSize).sorted()
        let body = bodySizes.isEmpty ? 11 : bodySizes[bodySizes.count / 2]
        let lengths = lines.filter { $0.fontSize == body }.map { $0.text.count }.sorted()
        let typicalLength = lengths.isEmpty ? 60 : lengths[Int(Double(lengths.count) * 0.8)]

        var result: [DocxParagraph] = []
        var current: [DocxRun] = []
        var currentStyle: DocxParagraph.Style = .normal
        var currentText = ""

        func style(for line: StyledLine) -> DocxParagraph.Style {
            if line.fontSize >= body * 1.6 { return .heading1 }
            if line.fontSize >= body * 1.3 { return .heading2 }
            if line.fontSize >= body * 1.12 || (line.bold && line.text.count < 80) { return .heading3 }
            return .normal
        }
        func flush() {
            if !current.isEmpty { result.append(DocxParagraph(runs: current, style: currentStyle)) }
            current = []
            currentText = ""
        }
        let listMarker = try? NSRegularExpression(pattern: #"^\s*([•·\-–*]|\d+[.)]|[a-zA-Z][.)]|[一二三四五六七八九十]+[、.])\s"#)

        for (i, line) in lines.enumerated() {
            if line.text.isEmpty {
                flush()
                continue
            }
            let lineStyle = style(for: line)
            let startsList = listMarker?.firstMatch(in: line.text, range: NSRange(location: 0, length: (line.text as NSString).length)) != nil
            if !current.isEmpty && (lineStyle != currentStyle || startsList) {
                flush()
            }
            if current.isEmpty {
                currentStyle = lineStyle
                current = line.runs
                currentText = line.text
            } else {
                let joiner = TextRecognizer.joiner(currentText, line.text, separator: " ")
                let separator = String(joiner.dropLast(line.text.count))
                if !separator.isEmpty { current.append(DocxRun(separator)) }
                // "exam-" + "ple" → "example", but keep "well-" + "Known".
                if currentText.hasSuffix("-"), line.text.first?.isLowercase == true, var last = current.popLast() {
                    last.text = String(last.text.dropLast())
                    current.append(last)
                }
                current.append(contentsOf: line.runs)
                currentText += separator + line.text
            }
            let isShort = line.text.count < Int(Double(typicalLength) * 0.7)
            let next = i + 1 < lines.count ? lines[i + 1] : nil
            if lineStyle != .normal || isShort || next == nil {
                flush()
            }
        }
        flush()
        return result
    }
}
