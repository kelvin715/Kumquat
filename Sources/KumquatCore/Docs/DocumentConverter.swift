import AppKit

/// Rich text documents (DOCX, DOC, RTF, ODT, HTML, TXT, Markdown) via AppKit's text system.
public enum DocumentConverter {
    public static func convert(_ input: URL, to format: OutputFormat) async throws -> [URL] {
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        // The HTML importer uses WebKit and AppKit text drawing expects the main thread.
        let output = try await MainActor.run { () throws -> URL in
            let document = try read(input)
            return try OutputNaming.write(to: destination) { out in
                try write(document, as: format, to: out, title: OutputNaming.baseName(of: input))
            }
        }
        return [output]
    }

    // MARK: - Reading

    @MainActor
    public static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            let text = try readPlainText(url)
            return MarkdownBridge.attributedString(fromMarkdown: text)
        case "txt", "text":
            let text = try readPlainText(url)
            let attributes: [NSAttributedString.Key: Any] = [.font: MarkdownBridge.regular(12)]
            return NSAttributedString(string: text, attributes: attributes)
        default:
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            switch ext {
            case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
            case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
            case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
            case "rtfd": options[.documentType] = NSAttributedString.DocumentType.rtfd
            case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
            case "html", "htm":
                options[.documentType] = NSAttributedString.DocumentType.html
                options[.characterEncoding] = String.Encoding.utf8.rawValue
            case "webarchive": options[.documentType] = NSAttributedString.DocumentType.webArchive
            default: break
            }
            do {
                return try NSAttributedString(url: url, options: options, documentAttributes: nil)
            } catch {
                throw KumquatError.decodeFailed(url.lastPathComponent)
            }
        }
    }

    static func readPlainText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        let data = try Data(contentsOf: url)
        // GB 18030 covers most Chinese text files that aren't UTF-8.
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for candidate in [String.Encoding.utf8, gb18030, .utf16, .macOSRoman, .isoLatin1] {
            if let text = String(data: data, encoding: candidate) { return text }
        }
        throw KumquatError.decodeFailed(url.lastPathComponent)
    }

    // MARK: - Writing

    @MainActor
    public static func write(_ document: NSAttributedString, as format: OutputFormat, to url: URL, title: String) throws {
        let range = NSRange(location: 0, length: document.length)
        func export(_ type: NSAttributedString.DocumentType) throws {
            let data = try document.data(from: range, documentAttributes: [.documentType: type, .title: title])
            try data.write(to: url)
        }
        switch format {
        case .docx: try export(.officeOpenXML)
        case .rtf: try export(.rtf)
        case .odt: try export(.openDocument)
        case .html: try export(.html)
        case .txt:
            try document.string.write(to: url, atomically: false, encoding: .utf8)
        case .md:
            try MarkdownBridge.markdown(from: document).write(to: url, atomically: false, encoding: .utf8)
        case .pdf:
            try AttributedPDFRenderer.render(document, to: url, title: title)
        default:
            throw KumquatError.unsupportedConversion(from: "document", to: format.title)
        }
    }
}

/// Lays rich text out on pages with TextKit and draws it into a PDF.
public enum AttributedPDFRenderer {
    @MainActor
    public static func render(_ text: NSAttributedString, to url: URL, title: String,
                              pageSize: CGSize? = nil, margin: CGFloat = 72) throws {
        let size = pageSize ?? (Locale.current.measurementSystem == .us
            ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89))
        let content = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin)

        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " "))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        while containers.count < 5000 {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }

        var media = CGRect(origin: .zero, size: size)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Kumquat"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            throw KumquatError.encodeFailed(url.lastPathComponent)
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for container in containers {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let glyphs = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
