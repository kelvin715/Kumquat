import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageConverter {
    public static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                               capabilities: Capabilities) async throws -> [URL] {
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        switch format {
        case .jpg, .png, .heic, .tiff, .bmp, .gif:
            return [try OutputNaming.write(to: destination) { try writeImageIO(input, to: $0, format: format, options: options) }]
        case .avif:
            if capabilities.canWriteAVIF {
                return [try OutputNaming.write(to: destination) { try writeImageIO(input, to: $0, format: .avif, options: options) }]
            }
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.toolMissing("ffmpeg") }
            return [try await OutputNaming.write(to: destination) { out in
                try await withTemporaryPNG(of: input) { png in
                    try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", png.path,
                                                                "-frames:v", "1", "-c:v", "libsvtav1", "-crf", "30",
                                                                "-pix_fmt", "yuv420p", out.path])
                }
            }]
        case .webp:
            return [try await OutputNaming.write(to: destination) { out in
                try await writeWebP(input, to: out, options: options, capabilities: capabilities)
            }]
        case .pdf:
            return [try OutputNaming.write(to: destination) { try writePDF(images: [input], to: $0, quality: options.imageQuality) }]
        case .docx:
            return [try OutputNaming.write(to: destination) { try writeDocx(input, to: $0, options: options) }]
        case .mp4:
            return [try await OutputNaming.write(to: destination) { try await AnimatedImageVideo.writeMP4(from: input, to: $0) }]
        default:
            throw KumquatError.unsupportedConversion(from: input.pathExtension.uppercased(), to: format.title)
        }
    }

    // MARK: - ImageIO formats

    static func writeImageIO(_ input: URL, to output: URL, format: OutputFormat, options: ConversionOptions) throws {
        let src = try ImageIOHelpers.source(input)
        let props = ImageIOHelpers.properties(src)
        let type = ImageIOHelpers.utType(for: format)
        let frameCount = CGImageSourceGetCount(src)

        // Animated sources keep their animation when the target is GIF.
        if format == .gif && frameCount > 1 {
            try writeAnimatedGIF(from: src, to: output)
            return
        }

        // Lossy targets re-encode straight from the source, keeping EXIF, GPS and orientation.
        // (TIFF goes through the decoded path: ImageIO ignores LZW compression when copying from a source.)
        let keepsOrientationTag = [.jpg, .heic, .avif].contains(format)
        let opaqueOnly = format == .jpg || format == .bmp
        let sourceHasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        var destProps: [CFString: Any] = [:]
        if [.jpg, .heic, .avif].contains(format) {
            destProps[kCGImageDestinationLossyCompressionQuality] = options.imageQuality
        }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        if keepsOrientationTag && !(opaqueOnly && sourceHasAlpha) {
            // Re-encodes from the source and keeps EXIF/GPS/orientation.
            CGImageDestinationAddImageFromSource(dest, src, 0, destProps as CFDictionary)
        } else {
            var image = try ImageIOHelpers.loadImage(from: src, name: input.lastPathComponent)
            if opaqueOnly && ImageIOHelpers.hasAlpha(image) {
                image = ImageIOHelpers.flatten(image)
            }
            if format != .bmp && format != .gif {
                destProps.merge(ImageIOHelpers.portableMetadata(props, keepOrientation: false)) { a, _ in a }
            }
            if format == .tiff { ImageIOHelpers.applyLZW(&destProps) }
            CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }

    static func writeAnimatedGIF(from src: CGImageSource, to output: URL) throws {
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let delay = frameDelay(ImageIOHelpers.properties(src, index: i))
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }

    /// Frame duration from whichever animation dictionary the source format uses.
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dict, unclamped, clamped) in dictionaries {
            if let d = props[dict] as? [CFString: Any] {
                let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
                if value > 0 { return max(value, 0.02) }
            }
        }
        return 0.1
    }

    // MARK: - WebP

    static func writeWebP(_ input: URL, to output: URL, options: ConversionOptions, capabilities: Capabilities) async throws {
        if let cwebp = capabilities.cwebpURL, !options.webpLossless {
            try await withTemporaryPNG(of: input) { png in
                try await ExternalTools.runChecked(cwebp, ["-quiet", "-mt", "-q", String(Int(options.webpQuality)),
                                                           "-metadata", "icc", png.path, "-o", output.path])
            }
            return
        }
        let image = try ImageIOHelpers.loadImage(input)
        try encodeWebPLossless(image, to: output)
    }

    public static func encodeWebPLossless(_ image: CGImage, to output: URL) throws {
        guard let buffer = RGBABuffer(image: image) else { throw KumquatError.decodeFailed("image") }
        try VP8LEncoder.encode(buffer).write(to: output)
    }

    /// Writes an upright PNG copy of the image to a temporary file for command-line encoders.
    static func withTemporaryPNG(of input: URL, _ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Kumquat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("input.png")
        let image = try ImageIOHelpers.loadImage(input)
        try ImageIOHelpers.write(image, to: png, type: .png)
        try await body(png)
    }

    // MARK: - PDF

    /// One page per image. Page size follows the image's DPI (like Preview), capped at A4.
    /// Opaque images are embedded as JPEG so the PDF stays close to the original size.
    public static func writePDF(images: [URL], to output: URL, quality: Double) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        for url in images {
            let src = try ImageIOHelpers.source(url)
            let props = ImageIOHelpers.properties(src)
            let image = try ImageIOHelpers.loadImage(from: src, name: url.lastPathComponent)
            let dpi = max(72, (props[kCGImagePropertyDPIWidth] as? Double) ?? 72)
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            // Camera photos claim 72 dpi, which would make 40-inch pages. Keep pages at most
            // A4-sized; the pixels are untouched, they just print at a higher resolution.
            let longest = max(box.width, box.height)
            if longest > 842 {
                box.size = CGSize(width: box.width * 842 / longest, height: box.height * 842 / longest)
            }
            let drawable = pdfDrawableImage(image, quality: quality) ?? image
            ctx.beginPage(mediaBox: &box)
            ctx.interpolationQuality = .high
            ctx.draw(drawable, in: box)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    static func pdfDrawableImage(_ image: CGImage, quality: Double) -> CGImage? {
        guard !ImageIOHelpers.hasTransparency(image),
              let jpeg = try? ImageIOHelpers.encode(ImageIOHelpers.flatten(image), type: .jpeg,
                                                   properties: [kCGImageDestinationLossyCompressionQuality: quality]),
              let provider = CGDataProvider(data: jpeg as CFData)
        else { return nil }
        // Quartz passes JPEG data straight into the PDF when the image is backed by it.
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - DOCX

    /// The picture itself, followed by any text recognized in it (editable in Word/Pages).
    static func writeDocx(_ input: URL, to output: URL, options: ConversionOptions) throws {
        let image = try ImageIOHelpers.loadImage(input)
        var doc = DocxDocument(title: OutputNaming.baseName(of: input))
        let embedded = try embeddableImageData(image)
        doc.append(DocxImage.fitted(data: embedded.data, fileExtension: embedded.ext,
                                    pixelWidth: image.width, pixelHeight: image.height,
                                    maxWidth: doc.textWidth, maxHeight: doc.textHeight * 0.9))
        let ocrImage = downscaled(image, maxPixel: 4096)
        let paragraphs = (try? TextRecognizer.recognizeText(in: ocrImage, languages: options.recognitionLanguages)) ?? []
        for text in paragraphs {
            doc.append(DocxParagraph(text))
        }
        try DocxWriter.write(doc, to: output)
    }

    static func embeddableImageData(_ image: CGImage) throws -> (data: Data, ext: String) {
        if ImageIOHelpers.hasTransparency(image) {
            return (try ImageIOHelpers.encode(image, type: .png), "png")
        }
        return (try ImageIOHelpers.encode(ImageIOHelpers.flatten(image), type: .jpeg,
                                          properties: [kCGImageDestinationLossyCompressionQuality: 0.9]), "jpeg")
    }

    public static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
