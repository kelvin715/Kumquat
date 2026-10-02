@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum VideoConverter {
    public static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                               capabilities: Capabilities) async throws -> [URL] {
        switch format {
        case .m4a, .mp3:
            return try await AudioConverter.convert(input, to: format, capabilities: capabilities)
        case .gif:
            let destination = OutputNaming.convertedURL(for: input, ext: "gif")
            if await MediaSupport.isReadable(input) {
                return [try await OutputNaming.write(to: destination) { try await makeGIF(from: input, to: $0, options: options) }]
            }
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
            let size = options.gifMaxWidth
            let filter = "fps=\(Int(options.gifFrameRate)),scale='if(gt(iw,ih),\(size),-2)':'if(gt(iw,ih),-2,\(size))':flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
            return [try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-t", String(options.gifMaxDuration),
                                                            "-i", input.path, "-vf", filter, "-loop", "0", out.path])
            }]
        case .mp4, .mov:
            return [try await convertContainer(input, to: format, capabilities: capabilities)]
        case .webm:
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.toolMissing("ffmpeg") }
            let destination = OutputNaming.convertedURL(for: input, ext: "webm")
            return [try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                                                            "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0",
                                                            "-deadline", "good", "-cpu-used", "4", "-row-mt", "1",
                                                            "-c:a", "libopus", "-b:a", "128k", out.path])
            }]
        default:
            throw KumquatError.unsupportedConversion(from: input.pathExtension.uppercased(), to: format.title)
        }
    }

    /// MP4 ⇄ MOV. Rewraps without re-encoding whenever the codecs allow it.
    static func convertContainer(_ input: URL, to format: OutputFormat, capabilities: Capabilities) async throws -> URL {
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        let fileType: AVFileType = format == .mp4 ? .mp4 : .mov

        if await MediaSupport.isReadable(input) {
            let asset = AVURLAsset(url: input)
            let passthrough = await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType)
            let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw KumquatError.encodeFailed(destination.lastPathComponent)
            }
            return try await OutputNaming.write(to: destination) { out in
                try await MediaSupport.export(session, to: out, as: fileType)
            }
        }

        guard let ffmpeg = capabilities.ffmpegURL else {
            throw KumquatError.unsupportedInput("\(input.lastPathComponent) (install ffmpeg to open it)")
        }
        return try await OutputNaming.write(to: destination) { out in
            // Try a lossless rewrap first (e.g. MKV with H.264 + AAC), then fall back to re-encoding.
            let copy = try await ExternalTools.run(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                                                            "-c", "copy", "-movflags", "+faststart", out.path])
            if copy.status != 0 {
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                                                            "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                                                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
                                                            "-movflags", "+faststart", out.path])
            }
        }
    }

    /// Animated GIF from the first `gifMaxDuration` seconds, longest side capped at `gifMaxWidth`.
    static func makeGIF(from input: URL, to output: URL, options: ConversionOptions) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let length = min(max(duration, 0.1), options.gifMaxDuration)
        let fps = options.gifFrameRate
        let count = max(1, Int(length * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let size = CGFloat(options.gifMaxWidth)
        generator.maximumSize = CGSize(width: size, height: size)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            if let image = try? result.image {
                CGImageDestinationAddImage(dest, image, frameProps)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }
}

/// Animated GIF / WebP / PNG → H.264 MP4.
public enum AnimatedImageVideo {
    public static func writeMP4(from input: URL, to output: URL) async throws {
        let src = try ImageIOHelpers.source(input)
        let count = CGImageSourceGetCount(src)
        guard let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let width = max(2, first.width & ~1), height = max(2, first.height & ~1)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(800_000, width * height * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        writer.add(input)
        guard writer.startWriting() else {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for i in 0..<count {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let delay = count > 1 ? ImageConverter.frameDelay(ImageIOHelpers.properties(src, index: i)) : 1
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = pixelBuffer(for: frame, width: width, height: height) else { continue }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += delay
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't write the video.")
        }
    }

    static func pixelBuffer(for image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        // Transparent GIF pixels have no video equivalent; show them as white.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
