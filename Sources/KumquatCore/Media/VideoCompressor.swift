@preconcurrency import AVFoundation
import Foundation

/// HEVC re-encoder used by the Compress tool. Unlike the fixed export presets it targets a
/// bitrate relative to the source, so it shrinks low-bitrate clips too.
enum VideoCompressor {
    static let maxDimension: CGFloat = 1920

    static func compress(_ input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw KumquatError.nothingToDo("\(input.lastPathComponent) has no video.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let sourceBitRate = Double(try await videoTrack.load(.estimatedDataRate))

        let scale = min(1, maxDimension / max(natural.width, natural.height, 1))
        let width = max(2, Int((natural.width * scale).rounded()) & ~1)
        let height = max(2, Int((natural.height * scale).rounded()) & ~1)
        let fps = frameRate > 0 ? frameRate : 30
        // About half the source bitrate (adjusted for any downscale), within sane bounds for HEVC.
        let ceiling = Double(width * height) * fps * 0.09
        var bitRate = sourceBitRate > 0 ? sourceBitRate * 0.5 * Double(scale * scale) : ceiling
        bitRate = max(250_000, min(bitRate, ceiling))

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        var codec = AVVideoCodecType.hevc
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(bitRate),
                    AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ]
        }
        if !writer.canApply(outputSettings: settings(codec), forMediaType: .video) { codec = .h264 }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings(codec))
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        writer.add(videoInput)

        var pumps = [SamplePump(reader: reader, output: videoOutput, input: videoInput)]
        if !audioTracks.isEmpty {
            let source = await MediaSupport.audioFormat(of: input)
            let rate = MediaSupport.aacSampleRate(for: min(source.sampleRate, 48000))
            let channels = min(source.channels, 2)
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks,
                                                          audioSettings: MediaSupport.pcmSettings(sampleRate: rate, channels: channels))
            let audioInput = AVAssetWriterInput(mediaType: .audio,
                                                outputSettings: MediaSupport.aacSettings(sampleRate: rate, channels: channels, bitRate: 128_000))
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput) && writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pumps.append(SamplePump(reader: reader, output: audioOutput, input: audioInput))
            }
        }

        guard reader.startReading() else {
            throw KumquatError.processFailed(reader.error?.localizedDescription ?? "Couldn't read \(input.lastPathComponent).")
        }
        guard writer.startWriting() else {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't write \(output.lastPathComponent).")
        }
        writer.startSession(atSourceTime: .zero)

        let running = pumps
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for pump in running { group.addTask { await pump.run() } }
            }
        } onCancel: {
            reader.cancelReading()
        }
        if Task.isCancelled {
            writer.cancelWriting()
            throw KumquatError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw KumquatError.processFailed(reader.error?.localizedDescription ?? "Reading failed.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't write the video.")
        }
    }
}
