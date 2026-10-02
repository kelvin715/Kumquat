import Foundation

/// A small WordprocessingML (DOCX) writer: styled paragraphs, page breaks and inline images.
/// AppKit's own DOCX export drops images, which matters for image → DOCX and scanned PDFs.
public struct DocxDocument {
    public enum Block {
        case paragraph(DocxParagraph)
        case image(DocxImage)
        case pageBreak
    }

    public enum PageSize {
        case letter, a4

        /// Width and height in twentieths of a point.
        var twips: (width: Int, height: Int) {
            switch self {
            case .letter: return (12240, 15840)
            case .a4: return (11906, 16838)
            }
        }

        public static var current: PageSize {
            Locale.current.measurementSystem == .us ? .letter : .a4
        }
    }

    public var blocks: [Block] = []
    public var title: String?
    public var pageSize: PageSize = .current

    public init(title: String? = nil) {
        self.title = title
    }

    public mutating func append(_ paragraph: DocxParagraph) { blocks.append(.paragraph(paragraph)) }
    public mutating func append(_ image: DocxImage) { blocks.append(.image(image)) }
    public mutating func appendPageBreak() { blocks.append(.pageBreak) }

    /// Usable text width in points (1 inch margins).
    public var textWidth: Double { Double(pageSize.twips.width) / 20 - 144 }
    public var textHeight: Double { Double(pageSize.twips.height) / 20 - 144 }
}

public struct DocxParagraph {
    public enum Style: String {
        case normal = "Normal"
        case title = "Title"
        case heading1 = "Heading1"
        case heading2 = "Heading2"
        case heading3 = "Heading3"
    }

    public enum Alignment: String {
        case left, center, right, both
    }

    public var runs: [DocxRun]
    public var style: Style
    public var alignment: Alignment?

    public init(_ text: String, style: Style = .normal, alignment: Alignment? = nil) {
        self.runs = [DocxRun(text)]
        self.style = style
        self.alignment = alignment
    }

    public init(runs: [DocxRun], style: Style = .normal, alignment: Alignment? = nil) {
        self.runs = runs
        self.style = style
        self.alignment = alignment
    }
}

public struct DocxRun {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    /// Font size in points.
    public var fontSize: Double?
    /// "RRGGBB"
    public var color: String?
    public var fontName: String?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                fontSize: Double? = nil, color: String? = nil, fontName: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.fontSize = fontSize
        self.color = color
        self.fontName = fontName
    }
}

public struct DocxImage {
    public var data: Data
    /// "png" or "jpeg"
    public var fileExtension: String
    /// Display size in points.
    public var width: Double
    public var height: Double

    public init(data: Data, fileExtension: String, width: Double, height: Double) {
        self.data = data
        self.fileExtension = fileExtension
        self.width = width
        self.height = height
    }

    /// Scales a pixel size to fit inside the given box (in points), never upscaling past 1px = 0.75pt.
    public static func fitted(data: Data, fileExtension: String, pixelWidth: Int, pixelHeight: Int,
                              maxWidth: Double, maxHeight: Double) -> DocxImage {
        var w = Double(pixelWidth) * 0.75
        var h = Double(pixelHeight) * 0.75
        let scale = min(1, maxWidth / max(w, 1), maxHeight / max(h, 1))
        w *= scale
        h *= scale
        return DocxImage(data: data, fileExtension: fileExtension, width: w, height: h)
    }
}

public enum DocxWriter {
    public static func data(for document: DocxDocument) -> Data {
        var zip = ZipWriter()
        var images: [(name: String, data: Data)] = []
        var body = ""

        for block in document.blocks {
            switch block {
            case .paragraph(let p):
                body += paragraphXML(p)
            case .pageBreak:
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            case .image(let image):
                let index = images.count + 1
                let ext = image.fileExtension == "jpg" ? "jpeg" : image.fileExtension
                images.append(("image\(index).\(ext)", image.data))
                body += imageXML(image, index: index)
            }
        }

        let (pageW, pageH) = document.pageSize.twips
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <w:body>\(body)<w:sectPr><w:pgSz w:w="\(pageW)" w:h="\(pageH)"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """

        var rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for (i, image) in images.enumerated() {
            rels += #"<Relationship Id="rIdImage\#(i + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\#(image.name)"/>"#
        }
        rels += "</Relationships>"

        zip.add("[Content_Types].xml", text: contentTypes)
        zip.add("_rels/.rels", text: packageRels)
        zip.add("word/document.xml", text: documentXML)
        zip.add("word/styles.xml", text: styles)
        zip.add("word/_rels/document.xml.rels", text: rels)
        for image in images {
            zip.add("word/media/\(image.name)", data: image.data, compress: false)
        }
        zip.add("docProps/core.xml", text: coreProperties(title: document.title))
        zip.add("docProps/app.xml", text: appProperties)
        return zip.finish()
    }

    public static func write(_ document: DocxDocument, to url: URL) throws {
        try data(for: document).write(to: url)
    }

    // MARK: - XML pieces

    static func paragraphXML(_ p: DocxParagraph) -> String {
        var xml = "<w:p>"
        if p.style != .normal || p.alignment != nil {
            xml += "<w:pPr>"
            if p.style != .normal { xml += #"<w:pStyle w:val="\#(p.style.rawValue)"/>"# }
            if let a = p.alignment { xml += #"<w:jc w:val="\#(a.rawValue)"/>"# }
            xml += "</w:pPr>"
        }
        for run in p.runs where !run.text.isEmpty {
            xml += runXML(run)
        }
        return xml + "</w:p>"
    }

    static func runXML(_ run: DocxRun) -> String {
        var props = ""
        if let font = run.fontName {
            let f = escape(font)
            props += #"<w:rFonts w:ascii="\#(f)" w:hAnsi="\#(f)" w:cs="\#(f)"/>"#
        }
        if run.bold { props += "<w:b/>" }
        if run.italic { props += "<w:i/>" }
        if let color = run.color { props += #"<w:color w:val="\#(color)"/>"# }
        if let size = run.fontSize {
            let half = max(2, Int((size * 2).rounded()))
            props += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"#
        }
        if run.underline { props += #"<w:u w:val="single"/>"# }

        var xml = "<w:r>"
        if !props.isEmpty { xml += "<w:rPr>\(props)</w:rPr>" }
        // Line breaks and tabs are separate elements inside a run.
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                xml += #"<w:t xml:space="preserve">\#(escape(buffer))</w:t>"#
                buffer = ""
            }
        }
        for ch in run.text {
            switch ch {
            case "\n", "\r", "\r\n", "\u{2028}":
                flush()
                xml += "<w:br/>"
            case "\t":
                flush()
                xml += "<w:tab/>"
            default:
                buffer.append(ch)
            }
        }
        flush()
        return xml + "</w:r>"
    }

    static func imageXML(_ image: DocxImage, index: Int) -> String {
        let cx = Int(image.width * 12700)
        let cy = Int(image.height * 12700)
        return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(index)" name="Picture \(index)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(index)" name="image\(index)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdImage\(index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
        </a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    /// XML-escapes text and drops characters XML 1.0 can't carry.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = scalar.value
                if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD)
                    || v >= 0x10000 {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
    </Types>
    """

    static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr>\
    <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="PingFang SC" w:cs="Calibri"/>\
    <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="zh-CN"/>\
    </w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
    </w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>\
    <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr>\
    <w:rPr><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
    <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="120"/>\
    <w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/>\
    <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/>\
    <w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/>\
    <w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/>\
    <w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style>\
    </w:styles>
    """

    static func coreProperties(title: String?) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let titleXML = title.map { "<dc:title>\(escape($0))</dc:title>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(titleXML)<dc:creator>Kumquat</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
    <Application>Kumquat</Application></Properties>
    """
}
