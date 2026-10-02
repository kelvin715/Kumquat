@preconcurrency import AVFoundation
import Foundation

public enum AudioConverter {
    /// Converts audio files, and extracts the soundtrack from videos (M4A / MP3).
    public static func convert(_ input: URL, to format: OutputFormat, capabilities: Capabilities) async throws -> [URL] {
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        let readable = await MediaSupport.isReadable(input)

        let needsFFmpeg: Bool = format == OutputFormat.mp3 || !readable
        if needsFFmpeg {
            guard let ffmpeg = capabilities.ffmpegURL else {
                throw readable ? KumquatError.toolMissing("ffmpeg")
                    : KumquatError.unsupportedInput("\(input.lastPathComponent) (install ffmpeg to open it)")
            }
            return [try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path, "-vn"]
                    + ffmpegAudioArguments(format) + [out.path])
            }]
        }

        let source = await MediaSupport.audioFormat(of: input)
        let channels = min(source.channels, 2)
        return [try await OutputNaming.write(to: destination) { out in
            switch format {
            case .m4a:
                let rate = MediaSupport.aacSampleRate(for: source.sampleRate)
                try await MediaSupport.transcodeAudio(
                    from: input, to: out, fileType: .m4a,
                    readerSettings: MediaSupport.pcmSettings(sampleRate: rate, channels: channels),
                    outputSettings: MediaSupport.aacSettings(sampleRate: rate, channels: channels,
                                                             bitRate: channels == 1 ? 128_000 : 256_000))
            case .wav, .aiff:
                let settings = MediaSupport.pcmSettings(sampleRate: source.sampleRate, channels: channels,
                                                        bigEndian: format == .aiff)
                try await MediaSupport.transcodeAudio(
                    from: input, to: out, fileType: format == .wav ? .wav : .aiff,
                    readerSettings: MediaSupport.pcmSettings(sampleRate: source.sampleRate, channels: channels),
                    outputSettings: settings)
            case .flac:
                try writeFLAC(from: input, to: out)
            default:
                throw KumquatError.unsupportedConversion(from: input.pathExtension.uppercased(), to: format.title)
            }
        }]
    }

    static func ffmpegAudioArguments(_ format: OutputFormat) -> [String] {
        switch format {
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-c:a", "aac", "-b:a", "256k"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .aiff: return ["-c:a", "pcm_s16be"]
        case .flac: return ["-c:a", "flac"]
        default: return []
        }
    }

    /// FLAC through Core Audio's encoder, chunk by chunk.
    static func writeFLAC(from input: URL, to output: URL) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
        ]
        let destination = try AVAudioFile(forWriting: output, settings: settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
        }
    }

    /// AAC at 128 kbps — typically a fraction of the size of WAV/AIFF/FLAC or 256k files.
    public static func compress(_ input: URL, capabilities: Capabilities) async throws -> URL {
        let destination = OutputNaming.taggedURL(for: input, tag: "Compressed", ext: "m4a")
        guard await MediaSupport.isReadable(input) else {
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
            return try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path, "-vn",
                                                            "-c:a", "aac", "-b:a", "128k", out.path])
            }
        }
        let source = await MediaSupport.audioFormat(of: input)
        let channels = min(source.channels, 2)
        let rate = MediaSupport.aacSampleRate(for: min(source.sampleRate, 44100))
        return try await OutputNaming.write(to: destination) { out in
            try await MediaSupport.transcodeAudio(
                from: input, to: out, fileType: .m4a,
                readerSettings: MediaSupport.pcmSettings(sampleRate: rate, channels: channels),
                outputSettings: MediaSupport.aacSettings(sampleRate: rate, channels: channels,
                                                         bitRate: channels == 1 ? 64_000 : 128_000))
        }
    }
}
