import Foundation

/// Runs a non-interactive wheel action over one or more files.
public struct ConversionEngine: Sendable {
    public struct Report: Sendable {
        public var outputs: [URL] = []
        public var failures: [(url: URL, message: String)] = []
        /// Extra detail for the toast, e.g. "62% smaller".
        public var note: String?
        /// How much smaller the Compress tool made the files, in percent.
        public var savedPercent: Int?
    }

    public var capabilities: Capabilities
    public var options: ConversionOptions

    public init(capabilities: Capabilities, options: ConversionOptions) {
        self.capabilities = capabilities
        self.options = options
    }

    /// `progress` receives (finished files, total files).
    public func run(_ action: WheelAction, on inputs: [URL],
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> Report {
        var report = Report()
        let files = inputs.filter { !FileClassifier.isDirectory($0) }

        // Merging turns many inputs into one output.
        if case .tool(.merge) = action {
            progress(0, 1)
            do {
                let kind = FileClassifier.kind(of: files[0])
                let merged: URL
                if kind == .pdf {
                    merged = try PDFTools.merge(files)
                } else {
                    let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let destination = OutputNaming.taggedURL(for: sorted[0], tag: "Merged", ext: "pdf")
                    merged = try OutputNaming.write(to: destination) {
                        try ImageConverter.writePDF(images: sorted, to: $0, quality: options.imageQuality)
                    }
                }
                report.outputs = [merged]
            } catch {
                report.failures.append((files.first ?? URL(fileURLWithPath: "/"), Self.message(for: error)))
            }
            progress(1, 1)
            return report
        }

        var savedBytes: Int64 = 0
        var originalBytes: Int64 = 0
        for (index, url) in files.enumerated() {
            progress(index, files.count)
            if Task.isCancelled {
                report.failures.append((url, KumquatError.cancelled.localizedDescription))
                break
            }
            do {
                switch action {
                case .convert(let format):
                    report.outputs += try await convert(url, to: format)
                case .tool(.compress):
                    let before = FileClassifier.fileSize(of: url)
                    let output = try await compress(url)
                    originalBytes += before
                    savedBytes += before - FileClassifier.fileSize(of: output)
                    report.outputs.append(output)
                case .tool(let tool):
                    report.outputs.append(try await runTool(tool, on: url))
                }
            } catch {
                report.failures.append((url, Self.message(for: error)))
            }
        }
        progress(files.count, files.count)
        if case .tool(.compress) = action, originalBytes > 0, savedBytes > 0 {
            let percent = Int((Double(savedBytes) / Double(originalBytes) * 100).rounded())
            report.savedPercent = percent
            report.note = "\(percent)% smaller"
        }
        return report
    }

    public func convert(_ url: URL, to format: OutputFormat) async throws -> [URL] {
        switch FileClassifier.kind(of: url) {
        case .image:
            return try await ImageConverter.convert(url, to: format, options: options, capabilities: capabilities)
        case .pdf:
            return try await PDFConverter.convert(url, to: format, options: options)
        case .document:
            return try await DocumentConverter.convert(url, to: format)
        case .video:
            return try await VideoConverter.convert(url, to: format, options: options, capabilities: capabilities)
        case .audio:
            return try await AudioConverter.convert(url, to: format, capabilities: capabilities)
        case .unsupported:
            throw KumquatError.unsupportedInput(url.lastPathComponent)
        }
    }

    public func compress(_ url: URL) async throws -> URL {
        switch FileClassifier.kind(of: url) {
        case .image:
            return try await ImageCompressor.compress(url, quality: options.compressQuality, capabilities: capabilities).url
        case .pdf:
            let output = try PDFTools.compress(url)
            if FileClassifier.fileSize(of: output) >= FileClassifier.fileSize(of: url) {
                try? FileManager.default.removeItem(at: output)
                throw KumquatError.nothingToDo("\(url.lastPathComponent) is already as small as it gets.")
            }
            return output
        case .video:
            return try await VideoTools.compress(url, capabilities: capabilities)
        case .audio:
            return try await AudioConverter.compress(url, capabilities: capabilities)
        default:
            throw KumquatError.unsupportedInput(url.lastPathComponent)
        }
    }

    /// Tools that run without a window (also used for multi-file drops).
    public func runTool(_ tool: ToolKind, on url: URL) async throws -> URL {
        let kind = FileClassifier.kind(of: url)
        switch (tool, kind) {
        case (.compress, _):
            return try await compress(url)
        case (.rotate, .pdf):
            return try PDFTools.rotate(url)
        case (.rotate, .video):
            return try await VideoTools.rotate(url)
        case (.split, .pdf):
            return try PDFTools.split(url)
        case (.mute, .video):
            return try await VideoTools.mute(url)
        case (.snapshot, .video):
            return try await VideoTools.snapshot(url)
        case (.metadata, .image):
            return try ImageMetadata.strip(url, mode: .everything)
        case (.metadata, .pdf):
            return try PDFTools.writeMetadata(url, metadata: PDFTools.Metadata(), tag: "No Metadata")
        default:
            throw KumquatError.unsupportedConversion(from: url.pathExtension.uppercased(), to: tool.title)
        }
    }

    public static func message(for error: Error) -> String {
        if let k = error as? KumquatError { return k.localizedDescription }
        if error is CancellationError { return KumquatError.cancelled.localizedDescription }
        return (error as NSError).localizedDescription
    }
}
