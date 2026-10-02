import Foundation

/// Optional command-line helpers (ffmpeg, cwebp). Apps launched from Finder get a minimal PATH,
/// so the usual Homebrew and MacPorts prefixes are searched explicitly.
public enum ExternalTools {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    public static func locate(_ name: String) -> URL? {
        var dirs = searchDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        let fm = FileManager.default
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public struct Output: Sendable {
        public var status: Int32
        public var standardError: String
    }

    /// Runs a tool to completion. Cancelling the surrounding task terminates the process.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                // Drain stderr on a background thread so a chatty tool can't fill the pipe and block.
                let collector = StderrCollector()
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if !data.isEmpty { collector.append(data) }
                }
                process.terminationHandler = { proc in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let rest = errPipe.fileHandleForReading.readDataToEndOfFile()
                    collector.append(rest)
                    continuation.resume(returning: Output(status: proc.terminationStatus,
                                                          standardError: collector.text))
                }
                do {
                    try process.run()
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        return output
    }

    /// Runs a tool and throws with the tail of its stderr when it fails.
    public static func runChecked(_ executable: URL, _ arguments: [String]) async throws {
        let result = try await run(executable, arguments)
        guard result.status == 0 else {
            let tail = result.standardError
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: "\n")
            throw KumquatError.processFailed("\(executable.lastPathComponent) failed: \(tail)")
        }
    }
}

private final class StderrCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        // Keep only the tail; ffmpeg can be verbose.
        data.append(chunk)
        if data.count > 64 * 1024 { data = data.suffix(32 * 1024) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
