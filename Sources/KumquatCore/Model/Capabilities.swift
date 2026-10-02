import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What this Mac can encode. Formats that can't be produced never appear on the wheel.
public struct Capabilities: Sendable {
    public var canWriteHEIC: Bool
    public var canWriteAVIF: Bool
    /// ffmpeg unlocks MP3/WebM output and inputs AVFoundation can't read (MKV, WebM, OGG...).
    public var ffmpegURL: URL?
    /// cwebp (from `brew install webp`) produces smaller lossy WebP files.
    /// Without it Kumquat uses its built-in lossless encoder.
    public var cwebpURL: URL?

    public init(canWriteHEIC: Bool, canWriteAVIF: Bool, ffmpegURL: URL?, cwebpURL: URL?) {
        self.canWriteHEIC = canWriteHEIC
        self.canWriteAVIF = canWriteAVIF
        self.ffmpegURL = ffmpegURL
        self.cwebpURL = cwebpURL
    }

    public static func detect(useExternalTools: Bool = true) -> Capabilities {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return Capabilities(
            canWriteHEIC: writable.contains(UTType.heic.identifier),
            canWriteAVIF: writable.contains("public.avif"),
            ffmpegURL: useExternalTools ? ExternalTools.locate("ffmpeg") : nil,
            cwebpURL: useExternalTools ? ExternalTools.locate("cwebp") : nil
        )
    }

    public var hasFFmpeg: Bool { ffmpegURL != nil }

    public func canProduce(_ format: OutputFormat) -> Bool {
        switch format {
        case .heic: return canWriteHEIC
        case .avif: return canWriteAVIF || hasFFmpeg
        case .mp3, .webm: return hasFFmpeg
        default: return true
        }
    }
}
