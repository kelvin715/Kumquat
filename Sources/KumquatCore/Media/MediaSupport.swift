@preconcurrency import AVFoundation
import Foundation

/// Shared AVFoundation plumbing.
enum MediaSupport {
    /// True when AVFoundation can open the file (MKV, WebM, OGG and friends usually can't).
    static func isReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let readable = try? await asset.load(.isReadable), readable else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        return !tracks.isEmpty
    }

    static func hasVideo(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    static func fileType(for ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "mov": return .mov
        case "m4a": return .m4a
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "caf": return .caf
        default: return nil
        }
    }

    /// Runs an export session, cancelling it if the surrounding task is cancelled.
    static func export(_ session: AVAssetExportSession, to url: URL, as type: AVFileType) async throws {
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        let box = SessionBox(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: KumquatError.cancelled)
                    default:
                        let message = box.session.error?.localizedDescription ?? "Export failed."
                        continuation.resume(throwing: KumquatError.processFailed(message))
                    }
                }
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// Decodes every audio track to PCM and re-encodes with `outputSettings`.
    static func transcodeAudio(from input: URL, to output: URL, fileType: AVFileType,
                               readerSettings: [String: Any], outputSettings: [String: Any],
                               timeRange: CMTimeRange? = nil) async throws {
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw KumquatError.nothingToDo("\(input.lastPathComponent) has no audio.") }
        let reader = try AVAssetReader(asset: asset)
        if let timeRange { reader.timeRange = timeRange }
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw KumquatError.processFailed(reader.error?.localizedDescription ?? "Couldn't read \(input.lastPathComponent).")
        }
        guard writer.startWriting() else {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't write \(output.lastPathComponent).")
        }
        writer.startSession(atSourceTime: timeRange?.start ?? .zero)

        let pump = SamplePump(reader: reader, output: readerOutput, input: writerInput)
        await withTaskCancellationHandler {
            await pump.run()
        } onCancel: {
            reader.cancelReading()
        }
        try Task.checkCancellation()
        if reader.status == .failed {
            writer.cancelWriting()
            throw KumquatError.processFailed(reader.error?.localizedDescription ?? "Reading failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Writing failed.")
        }
    }

    static func audioFormat(of url: URL) async -> (sampleRate: Double, channels: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let first = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee
        else { return (44100, 2) }
        return (asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100, max(1, Int(asbd.mChannelsPerFrame)))
    }

    static func pcmSettings(sampleRate: Double, channels: Int, bitDepth: Int = 16, bigEndian: Bool = false) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func aacSettings(sampleRate: Double, channels: Int, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: aacBitRate(bitRate, sampleRate: sampleRate, channels: channels),
        ]
    }

    /// The AAC encoder rejects bitrates above roughly 3 bits per sample per channel
    /// (e.g. 128 kbps for 22 kHz mono), so clamp to the nearest standard rate it accepts.
    static func aacBitRate(_ desired: Int, sampleRate: Double, channels: Int) -> Int {
        let limit = Int(sampleRate * Double(channels) * 3)
        let standard = [256_000, 192_000, 160_000, 128_000, 96_000, 64_000, 48_000, 32_000, 24_000, 16_000]
        return standard.first { $0 <= min(desired, limit) } ?? 16_000
    }

    /// Sample rates the AAC encoder accepts.
    static func aacSampleRate(for source: Double) -> Double {
        let supported: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        return supported.min { abs($0 - source) < abs($1 - source) } ?? 44100
    }
}

private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// Moves sample buffers from a reader output to a writer input on a private queue.
final class SamplePump: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let queue = DispatchQueue(label: "kumquat.sample-pump")

    init(reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }

    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
                        if !input.append(buffer) {
                            reader.cancelReading()
                        }
                    } else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
