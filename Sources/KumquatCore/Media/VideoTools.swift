@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum VideoTools {
    static func outputType(for input: URL) -> (ext: String, type: AVFileType) {
        let ext: String = input.pathExtension.lowercased()
        if ext == "mov" { return (ext: "mov", type: AVFileType.mov) }
        return (ext: "mp4", type: AVFileType.mp4)
    }

    /// Re-encodes with HEVC at about half the original bitrate, capped at 1080p.
    public static func compress(_ input: URL, capabilities: Capabilities) async throws -> URL {
        let destination = OutputNaming.taggedURL(for: input, tag: "Compressed", ext: "mp4")
        let originalSize = FileClassifier.fileSize(of: input)

        let output: URL
        if await MediaSupport.isReadable(input) {
            output = try await OutputNaming.write(to: destination) { try await VideoCompressor.compress(input, to: $0) }
        } else {
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
            output = try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                                                            "-vf", "scale='min(1920,iw)':-2", "-c:v", "libx265", "-crf", "28",
                                                            "-preset", "medium", "-tag:v", "hvc1", "-c:a", "aac", "-b:a", "128k",
                                                            "-movflags", "+faststart", out.path])
            }
        }
        if FileClassifier.fileSize(of: output) >= originalSize {
            try? FileManager.default.removeItem(at: output)
            throw KumquatError.nothingToDo("\(input.lastPathComponent) is already well compressed.")
        }
        return output
    }

    /// Same video without its audio tracks (no re-encoding).
    public static func mute(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw KumquatError.nothingToDo("\(input.lastPathComponent) has no video.") }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in videoTracks {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        let (ext, type) = outputType(for: input)
        return try await export(composition, from: input, tag: "Muted", ext: ext, type: type)
    }

    /// Rotates 90° clockwise by changing the display transform (instant, lossless).
    public static func rotate(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) {
            guard let target = composition.addMutableTrack(withMediaType: track.mediaType,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            if track.mediaType == .video {
                let transform = try await track.load(.preferredTransform)
                let natural = try await track.load(.naturalSize)
                let displayed = CGRect(origin: .zero, size: natural).applying(transform)
                let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: abs(displayed.height), ty: 0)
                target.preferredTransform = transform.concatenating(quarterTurn)
            }
        }
        let (ext, type) = outputType(for: input)
        return try await export(composition, from: input, tag: "Rotated", ext: ext, type: type)
    }

    /// A still frame, saved as PNG.
    public static func snapshot(_ input: URL, at seconds: Double? = nil) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        let time = seconds ?? min(1, duration / 3)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        let destination = OutputNaming.taggedURL(for: input, tag: "Snapshot", ext: "png")
        return try OutputNaming.write(to: destination) { try ImageIOHelpers.write(image, to: $0, type: .png) }
    }

    /// Keeps only `range`. Video and AAC audio are copied as-is; other audio becomes M4A.
    public static func trim(_ input: URL, range: CMTimeRange) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let isVideo = await MediaSupport.hasVideo(input)
        var ext = input.pathExtension.lowercased()
        var type = MediaSupport.fileType(for: ext)
        var preset = AVAssetExportPresetPassthrough
        if isVideo {
            if type == nil || type == .m4a { (ext, type) = ("mp4", .mp4) }
        } else if type == nil || ![AVFileType.m4a, .wav, .aiff, .caf].contains(type!) {
            (ext, type, preset) = ("m4a", .m4a, AVAssetExportPresetAppleM4A)
        }
        guard let fileType = type, let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw KumquatError.encodeFailed("trimmed file")
        }
        session.timeRange = range
        let destination = OutputNaming.taggedURL(for: input, tag: "Trimmed", ext: ext)
        return try await OutputNaming.write(to: destination) { out in
            try await MediaSupport.export(session, to: out, as: fileType)
        }
    }

    static func export(_ composition: AVComposition, from input: URL, tag: String, ext: String, type: AVFileType) async throws -> URL {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw KumquatError.encodeFailed(input.lastPathComponent)
        }
        let destination = OutputNaming.taggedURL(for: input, tag: tag, ext: ext)
        return try await OutputNaming.write(to: destination) { out in
            try await MediaSupport.export(session, to: out, as: type)
        }
    }
}
