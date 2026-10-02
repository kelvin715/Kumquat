import Foundation
import UniformTypeIdentifiers

/// Broad family a file belongs to. Decides which formats and tools the wheel offers.
public enum FileKind: String, Sendable {
    case image, pdf, document, video, audio, unsupported
}

public enum FileClassifier {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "gif", "webp", "heic", "heif", "avif", "tif", "tiff",
        "bmp", "jxl", "psd", "ico", "icns", "tga", "exr", "jp2", "j2k", "dng", "cr2", "cr3", "nef",
        "arw", "raf", "orf", "rw2", "srw", "pef",
    ]
    static let documentExtensions: Set<String> = [
        "docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "html", "htm", "webarchive",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "flv", "wmv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "ogg", "oga", "opus",
        "wma", "amr",
    ]

    public static func kind(of url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if documentExtensions.contains(ext) { return .document }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }

        guard let type = UTType(filenameExtension: ext) else { return .unsupported }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .rtf) || type.conforms(to: .html) || type.conforms(to: .plainText) {
            return .document
        }
        return .unsupported
    }

    /// The output format a file already is, so the wheel can leave it out.
    public static func sourceFormat(of url: URL) -> OutputFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": return .jpg
        case "png": return .png
        case "webp": return .webp
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "avif": return .avif
        case "bmp": return .bmp
        case "gif": return .gif
        case "pdf": return .pdf
        case "docx": return .docx
        case "txt", "text": return .txt
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "odt": return .odt
        case "md", "markdown": return .md
        case "mp4": return .mp4
        case "mov": return .mov
        case "webm": return .webm
        case "m4a": return .m4a
        case "mp3": return .mp3
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "flac": return .flac
        default: return nil
        }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && url.pathExtension.lowercased() != "rtfd"
    }

    public static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }
}
