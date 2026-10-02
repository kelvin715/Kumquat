import AppKit
import CoreText
import PDFKit

public enum PDFTools {
    /// Re-encodes embedded images as JPEG and downsamples them for screen use.
    public static func compress(_ input: URL) throws -> URL {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let destination = OutputNaming.taggedURL(for: input, tag: "Compressed")
        return try OutputNaming.write(to: destination) { out in
            let ok = doc.write(to: out, withOptions: [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: true,
            ])
            if !ok { throw KumquatError.encodeFailed(destination.lastPathComponent) }
        }
    }

    public static func rotate(_ input: URL, degrees: Int = 90) throws -> URL {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        let destination = OutputNaming.taggedURL(for: input, tag: "Rotated")
        return try OutputNaming.write(to: destination) { out in
            if !doc.write(to: out) { throw KumquatError.encodeFailed(destination.lastPathComponent) }
        }
    }

    /// One PDF per page in a "Name Pages" folder.
    public static func split(_ input: URL) throws -> URL {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        guard doc.pageCount > 1 else { throw KumquatError.nothingToDo("\(input.lastPathComponent) only has one page.") }
        let base = OutputNaming.baseName(of: input)
        let folder = try OutputNaming.makeDirectory(input.deletingLastPathComponent().appendingPathComponent("\(base) Pages"))
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(i + 1)
            let name = "\(base) - Page \(String(repeating: "0", count: digits - number.count))\(number).pdf"
            if !single.write(to: folder.appendingPathComponent(name)) {
                throw KumquatError.encodeFailed(name)
            }
        }
        return folder
    }

    /// Joins PDFs in Finder name order.
    public static func merge(_ inputs: [URL]) throws -> URL {
        let sorted = inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = sorted.first else { throw KumquatError.nothingToDo("Nothing to merge.") }
        let merged = PDFDocument()
        for url in sorted {
            guard let doc = PDFDocument(url: url) else { throw KumquatError.decodeFailed(url.lastPathComponent) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let destination = OutputNaming.taggedURL(for: first, tag: "Merged", ext: "pdf")
        return try OutputNaming.write(to: destination) { out in
            if !merged.write(to: out) { throw KumquatError.encodeFailed(destination.lastPathComponent) }
        }
    }

    // MARK: - Watermark

    public struct Watermark: Sendable {
        public var text: String
        public var fontSize: Double
        public var opacity: Double
        /// Degrees, counter-clockwise.
        public var angle: Double
        public var color: CGColor
        public var tiled: Bool

        public init(text: String, fontSize: Double = 48, opacity: Double = 0.18, angle: Double = 35,
                    color: CGColor = CGColor(red: 0.85, green: 0.2, blue: 0.05, alpha: 1), tiled: Bool = false) {
            self.text = text
            self.fontSize = fontSize
            self.opacity = opacity
            self.angle = angle
            self.color = color
            self.tiled = tiled
        }
    }

    /// Draws the watermark over each page. Page content stays vector.
    public static func watermark(_ input: URL, with mark: Watermark) throws -> URL {
        let doc = try PDFRenderer.document(at: input)
        let destination = OutputNaming.taggedURL(for: input, tag: "Watermarked")
        return try OutputNaming.write(to: destination) { out in
            guard let consumer = CGDataConsumer(url: out as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
            else { throw KumquatError.encodeFailed(destination.lastPathComponent) }
            for number in 1...max(1, doc.numberOfPages) {
                guard let page = doc.page(at: number) else { continue }
                let box = page.getBoxRect(.cropBox)
                let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
                var size = box.size
                if rotation == 90 || rotation == 270 { size = CGSize(width: size.height, height: size.width) }
                var media = CGRect(origin: .zero, size: size)
                ctx.beginPage(mediaBox: &media)
                ctx.saveGState()
                ctx.concatenate(PDFRenderer.displayTransform(box: box, rotation: rotation))
                ctx.clip(to: box)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
                drawWatermark(mark, in: ctx, size: size)
                ctx.endPage()
            }
            ctx.closePDF()
        }
    }

    public static func drawWatermark(_ mark: Watermark, in ctx: CGContext, size: CGSize) {
        guard !mark.text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, mark.fontSize, nil)
        let color = mark.color.copy(alpha: mark.opacity) ?? mark.color
        let attributed = NSAttributedString(string: mark.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, ctx)
        let radians = mark.angle * .pi / 180

        func stamp(at center: CGPoint) {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: radians)
            ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.minX, y: -bounds.height / 2 - bounds.minY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        if mark.tiled {
            let stepX = max(bounds.width * 1.3, 120), stepY = max(mark.fontSize * 4, 80)
            var y = -stepY
            var row = 0
            while y < size.height + stepY {
                var x = (row % 2 == 0 ? 0 : stepX / 2) - stepX
                while x < size.width + stepX {
                    stamp(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            stamp(at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    // MARK: - Metadata

    public struct Metadata: Sendable, Equatable {
        public var title = ""
        public var author = ""
        public var subject = ""
        public var keywords = ""
        public var creator = ""
        public var producer = ""
        public var created: Date?
        public var modified: Date?
        public var pageCount = 0
        public var isEncrypted = false
        public var version = ""

        public init() {}
    }

    public static func readMetadata(_ input: URL) throws -> Metadata {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let attrs = doc.documentAttributes ?? [:]
        var m = Metadata()
        m.title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        m.author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        m.subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        if let k = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            m.keywords = k.joined(separator: ", ")
        } else {
            m.keywords = attrs[PDFDocumentAttribute.keywordsAttribute] as? String ?? ""
        }
        m.creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String ?? ""
        m.producer = attrs[PDFDocumentAttribute.producerAttribute] as? String ?? ""
        m.created = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        m.modified = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        m.pageCount = doc.pageCount
        m.isEncrypted = doc.isEncrypted
        m.version = "\(doc.majorVersion).\(doc.minorVersion)"
        return m
    }

    /// Saves a copy with new document info. Passing an empty `Metadata` clears everything.
    public static func writeMetadata(_ input: URL, metadata: Metadata, tag: String) throws -> URL {
        guard let doc = PDFDocument(url: input) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        var attrs: [AnyHashable: Any] = [:]
        if !metadata.title.isEmpty { attrs[PDFDocumentAttribute.titleAttribute] = metadata.title }
        if !metadata.author.isEmpty { attrs[PDFDocumentAttribute.authorAttribute] = metadata.author }
        if !metadata.subject.isEmpty { attrs[PDFDocumentAttribute.subjectAttribute] = metadata.subject }
        if !metadata.keywords.isEmpty {
            attrs[PDFDocumentAttribute.keywordsAttribute] = metadata.keywords
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if !metadata.creator.isEmpty { attrs[PDFDocumentAttribute.creatorAttribute] = metadata.creator }
        if let created = metadata.created { attrs[PDFDocumentAttribute.creationDateAttribute] = created }
        doc.documentAttributes = attrs
        let destination = OutputNaming.taggedURL(for: input, tag: tag)
        return try OutputNaming.write(to: destination) { out in
            if !doc.write(to: out) { throw KumquatError.encodeFailed(destination.lastPathComponent) }
        }
    }
}
