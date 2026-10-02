import AppKit

/// Markdown ⇄ rich text. Import uses Foundation's CommonMark parser; export maps fonts and
/// attributes back to Markdown syntax.
public enum MarkdownBridge {
    static let bodySize: CGFloat = 12

    // Named fonts (not the private system UI font) so exported PDFs and DOCX files open
    // with the right typeface everywhere. CJK text falls back to PingFang automatically.
    static func regular(_ size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func bold(_ size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - Import

    public static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: regular(bodySize)])
        }

        let result = NSMutableAttributedString()
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            var font = regular(bodySize)
            var color = NSColor.textColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            var marker: String?
            var listDepth = 0

            for component in components {
                switch component.kind {
                case .header(let level):
                    let sizes: [CGFloat] = [24, 19, 16, 14, 13, 12]
                    font = bold(sizes[min(max(level, 1), 6) - 1])
                    paragraph.paragraphSpacingBefore = 10
                case .codeBlock:
                    font = mono(bodySize - 1)
                    paragraph.paragraphSpacing = 2
                case .blockQuote:
                    color = .secondaryLabelColor
                    paragraph.headIndent += 18
                    paragraph.firstLineHeadIndent += 18
                case .listItem(let ordinal):
                    listDepth += 1
                    if marker == nil {
                        let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                        marker = ordered ? "\(ordinal). " : "• "
                    }
                default:
                    break
                }
            }
            if listDepth > 0 {
                let indent = CGFloat(listDepth) * 20
                paragraph.headIndent = indent
                paragraph.firstLineHeadIndent = indent - 14
                paragraph.paragraphSpacing = 3
            }

            if let previousBlock, block != previousBlock { result.append(NSAttributedString(string: "\n")) }
            if block != previousBlock, let marker {
                result.append(NSAttributedString(string: marker, attributes: [.font: regular(bodySize),
                                                                               .paragraphStyle: paragraph]))
            }
            previousBlock = block

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = mono(font.pointSize - 1)
                }
                var traits: NSFontTraitMask = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    // MARK: - Export

    public static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        guard string.length > 0 else { return "" }

        // The most common font size is the body size; larger sizes become headings.
        var sizeCounts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            sizeCounts[size, default: 0] += range.length
        }
        let body = sizeCounts.max { $0.value < $1.value }?.key ?? 12

        var lines: [String] = []
        var index = 0
        var previousWasList = false
        while index < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(paragraphRange)
            var contentRange = paragraphRange
            while contentRange.length > 0,
                  let last = string.substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)).unicodeScalars.first,
                  CharacterSet.newlines.contains(last) {
                contentRange.length -= 1
            }
            let plain = string.substring(with: contentRange)
            if plain.trimmingCharacters(in: .whitespaces).isEmpty {
                if lines.last != "" { lines.append("") }
                previousWasList = false
                continue
            }

            var maxSize: CGFloat = 0
            text.enumerateAttribute(.font, in: contentRange) { value, _, _ in
                maxSize = max(maxSize, (value as? NSFont)?.pointSize ?? body)
            }
            let style = text.attribute(.paragraphStyle, at: contentRange.location, effectiveRange: nil) as? NSParagraphStyle
            let isList = !(style?.textLists.isEmpty ?? true) || plain.hasPrefix("• ") || plain.hasPrefix("◦ ")

            var prefix = ""
            if maxSize >= body * 1.6 { prefix = "# " }
            else if maxSize >= body * 1.3 { prefix = "## " }
            else if maxSize >= body * 1.12 { prefix = "### " }

            var inline = inlineMarkdown(text, range: contentRange, skipBold: !prefix.isEmpty)
            if isList {
                for bullet in ["• ", "◦ ", "- "] where inline.hasPrefix(bullet) {
                    inline = String(inline.dropFirst(bullet.count))
                }
                if let list = style?.textLists.first, list.markerFormat.rawValue.contains("decimal") {
                    prefix = "1. "
                } else {
                    prefix = "- "
                }
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                prefix = String(repeating: "  ", count: depth) + prefix
            }

            if !previousWasList || !isList, let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(prefix + inline)
            previousWasList = isList
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func inlineMarkdown(_ text: NSAttributedString, range: NSRange, skipBold: Bool) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attrs, r, _ in
            var piece = (text.string as NSString).substring(with: r)
            piece = piece.replacingOccurrences(of: "\u{2028}", with: "  \n")
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else {
                out += piece
                return
            }
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let monospaced = font?.isFixedPitch ?? false
            var core = piece.trimmingCharacters(in: .whitespaces)
            let leading = String(piece.prefix { $0 == " " })
            let trailing = String(piece.reversed().prefix { $0 == " " })
            if monospaced {
                core = "`\(core)`"
            } else {
                core = escape(core)
                if traits.contains(.italicFontMask) { core = "*\(core)*" }
                if traits.contains(.boldFontMask) && !skipBold { core = "**\(core)**" }
                if attrs[.strikethroughStyle] != nil { core = "~~\(core)~~" }
            }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? "\(link)"
                core = "[\(core)](\(href))"
            }
            out += leading + core + trailing
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
