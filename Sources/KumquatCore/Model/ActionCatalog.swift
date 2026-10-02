import Foundation

/// Decides which segments the wheel shows for a set of dragged files.
/// Segments are listed clockwise, starting at twelve o'clock.
public struct ActionCatalog: Sendable {
    public var capabilities: Capabilities

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// Actions for the given mode. The tools wheel falls back to formats when a file type has no tools.
    public func actions(for urls: [URL], mode: WheelMode) -> [WheelAction] {
        switch mode {
        case .formats:
            return formatActions(for: urls)
        case .tools:
            let tools = toolActions(for: urls)
            return tools.isEmpty ? formatActions(for: urls) : tools
        }
    }

    public func formatActions(for urls: [URL]) -> [WheelAction] {
        let files = urls.filter { !FileClassifier.isDirectory($0) }
        guard !files.isEmpty else { return [] }
        var common: [OutputFormat]?
        for url in files {
            let formats = formats(for: url)
            if let current = common {
                common = current.filter(formats.contains)
            } else {
                common = formats
            }
        }
        return (common ?? []).map { .convert($0) }
    }

    public func formats(for url: URL) -> [OutputFormat] {
        let source = FileClassifier.sourceFormat(of: url)
        let candidates: [OutputFormat]
        switch FileClassifier.kind(of: url) {
        case .pdf:
            candidates = [.docx, .jpg, .png, .txt]
        case .image:
            if source == .gif {
                candidates = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .mp4]
            } else {
                candidates = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx]
            }
        case .document:
            candidates = [.pdf, .docx, .rtf, .txt, .html, .odt, .md]
        case .video:
            candidates = [.mp4, .mov, .webm, .gif, .m4a, .mp3]
        case .audio:
            candidates = [.m4a, .mp3, .wav, .flac, .aiff]
        case .unsupported:
            candidates = []
        }
        return candidates.filter { $0 != source && capabilities.canProduce($0) }
    }

    public func toolActions(for urls: [URL]) -> [WheelAction] {
        let files = urls.filter { !FileClassifier.isDirectory($0) }
        guard !files.isEmpty else { return [] }
        let kinds = Set(files.map(FileClassifier.kind(of:)))
        guard kinds.count == 1, let kind = kinds.first else { return [] }
        let single = files.count == 1

        let tools: [ToolKind]
        switch kind {
        case .image:
            tools = single
                ? [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
                : [.compress, .merge, .metadata]
        case .pdf:
            tools = single
                ? [.compress, .rotate, .split, .watermark, .metadata]
                : [.compress, .merge, .rotate]
        case .video:
            tools = single
                ? [.compress, .trim, .mute, .rotate, .snapshot]
                : [.compress, .mute, .rotate, .snapshot]
        case .audio:
            tools = single ? [.trim, .compress] : [.compress]
        case .document, .unsupported:
            tools = []
        }
        return tools.map { .tool($0) }
    }

    /// Tools that open an editing window instead of running straight away.
    public static func isInteractive(_ tool: ToolKind, kind: FileKind, fileCount: Int) -> Bool {
        guard fileCount == 1 else { return false }
        switch tool {
        case .edit, .annotate, .addBackground, .crop, .redact, .watermark, .trim:
            return true
        case .metadata:
            return kind == .image || kind == .pdf
        case .compress, .rotate, .split, .merge, .mute, .snapshot:
            return false
        }
    }
}
