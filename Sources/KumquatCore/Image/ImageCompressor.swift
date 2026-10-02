import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCompressor {
    public struct Outcome: Sendable {
        public var url: URL
        public var originalSize: Int64
        public var newSize: Int64

        public var savedFraction: Double {
            originalSize > 0 ? 1 - Double(newSize) / Double(originalSize) : 0
        }
    }

    /// Smaller file in the same format where possible:
    /// JPEG/HEIC/AVIF/WebP are re-encoded at `quality` without metadata, PNG is palette-quantized,
    /// TIFF gets LZW compression and BMP (which can't compress) becomes PNG.
    public static func compress(_ input: URL, quality: Double, capabilities: Capabilities) async throws -> Outcome {
        let source = FileClassifier.sourceFormat(of: input)
        let originalSize = FileClassifier.fileSize(of: input)
        let src = try ImageIOHelpers.source(input)
        let image = try ImageIOHelpers.loadImage(from: src, name: input.lastPathComponent)
        let props = ImageIOHelpers.properties(src)
        // Keep the colour profile-related DPI but drop camera metadata and location.
        var keep: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let dpi = props[kCGImagePropertyDPIWidth] { keep[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = props[kCGImagePropertyDPIHeight] { keep[kCGImagePropertyDPIHeight] = dpi }

        let ext: String
        let write: (URL) async throws -> Void
        switch source {
        case .jpg, .heic, .avif:
            ext = input.pathExtension
            let type = ImageIOHelpers.utType(for: source!)
            write = { out in
                var p = keep
                p[kCGImageDestinationLossyCompressionQuality] = quality
                let opaque = source == .jpg ? ImageIOHelpers.flatten(image) : image
                try ImageIOHelpers.write(opaque, to: out, type: type, properties: p)
            }
        case .webp:
            ext = "webp"
            write = { out in
                if let cwebp = capabilities.cwebpURL {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-\(UUID().uuidString).png")
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    try ImageIOHelpers.write(image, to: tmp, type: .png)
                    try await ExternalTools.runChecked(cwebp, ["-quiet", "-mt", "-q", String(Int(quality * 100)), tmp.path, "-o", out.path])
                } else {
                    try ImageConverter.encodeWebPLossless(image, to: out)
                }
            }
        case .tiff:
            ext = input.pathExtension
            write = { out in
                var p = keep
                ImageIOHelpers.applyLZW(&p)
                try ImageIOHelpers.write(image, to: out, type: .tiff, properties: p)
            }
        default:
            // PNG, BMP, GIF and the rest: palette PNG.
            ext = source == .gif ? "gif" : "png"
            write = { out in
                guard let buffer = RGBABuffer(image: image) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
                if source == .gif {
                    try ImageIOHelpers.write(image, to: out, type: .gif)
                } else {
                    let quantized = PNGQuantizer.quantize(buffer, maxColors: quality >= 0.85 ? 256 : 192)
                    try PNGQuantizer.pngData(quantized).write(to: out)
                }
            }
        }

        let destination = OutputNaming.taggedURL(for: input, tag: "Compressed", ext: ext)
        let output = try await OutputNaming.write(to: destination, write)
        let newSize = FileClassifier.fileSize(of: output)
        if newSize >= originalSize && source != .bmp {
            try? FileManager.default.removeItem(at: output)
            throw KumquatError.nothingToDo("\(input.lastPathComponent) is already as small as it gets.")
        }
        return Outcome(url: output, originalSize: originalSize, newSize: newSize)
    }
}
