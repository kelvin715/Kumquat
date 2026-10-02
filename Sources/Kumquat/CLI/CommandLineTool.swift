import AppKit
import KumquatCore

/// `Kumquat <command> ...` — the same engine as the wheel, scriptable from Terminal.
enum CommandLineTool {
    static let commands: Set<String> = ["convert", "tool", "actions", "info", "render-previews", "self-test", "help", "--help", "-h"]

    /// Any bare word is treated as a command (unknown ones print usage), so a typo never
    /// launches the menu bar app. Flags such as `-NSDocumentRevisionsDebugMode` are left to AppKit.
    static func shouldHandle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        return commands.contains(arguments[1]) || !arguments[1].hasPrefix("-")
    }

    static let usage = """
    Kumquat — convert files from the command line.

      Kumquat convert <file>... --to <format>    jpg png webp heic tiff avif bmp gif pdf docx txt
                                                 rtf html odt md mp4 mov webm m4a mp3 wav aiff flac
      Kumquat tool <tool> <file>...              compress rotate split merge mute snapshot metadata
      Kumquat actions <file>...                  list what the wheels would offer
      Kumquat info <image>                       show image metadata
      Kumquat render-previews <folder>           render the wheel and tool windows to PNG

    Results are saved next to the originals.
    """

    @MainActor
    static func run(_ arguments: [String]) async -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.removeFirst()
        let capabilities = Capabilities.detect()
        let engine = ConversionEngine(capabilities: capabilities, options: AppSettings.shared.conversionOptions)

        switch command {
        case "convert":
            guard let toIndex = args.firstIndex(of: "--to"), toIndex + 1 < args.count,
                  let format = OutputFormat(rawValue: args[toIndex + 1].lowercased().replacingOccurrences(of: "jpeg", with: "jpg"))
            else {
                print(usage)
                return 64
            }
            var files = args
            files.removeSubrange(toIndex...(toIndex + 1))
            return await report(engine.run(.convert(format), on: files.map(fileURL)))

        case "tool":
            guard let name = args.first, let tool = ToolKind(rawValue: name) else {
                print("Unknown tool. Available: compress rotate split merge mute snapshot metadata")
                return 64
            }
            return await report(engine.run(.tool(tool), on: args.dropFirst().map(fileURL)))

        case "actions":
            let catalog = ActionCatalog(capabilities: capabilities)
            let urls = args.map(fileURL)
            print("Formats (⇧):  " + catalog.actions(for: urls, mode: .formats).map(\.title).joined(separator: "  "))
            print("Tools (⌥⇧):   " + catalog.actions(for: urls, mode: .tools).map(\.title).joined(separator: "  "))
            return 0

        case "info":
            guard let path = args.first else { return 64 }
            do {
                let summary = try ImageMetadata.summary(of: fileURL(path))
                for entry in summary.entries {
                    print("\(entry.section.padding(toLength: 9, withPad: " ", startingAt: 0)) \(entry.label): \(entry.value)")
                }
                return 0
            } catch {
                print(ConversionEngine.message(for: error))
                return 1
            }

        case "self-test":
            return SelfTest.run() ? 0 : 1

        case "render-previews":
            guard let path = args.first else { return 64 }
            return PreviewRenderer.renderAll(to: fileURL(path)) ? 0 : 1

        case "help", "--help", "-h":
            print(usage)
            return 0

        default:
            print("Unknown command: \(command)\n")
            print(usage)
            return 64
        }
    }

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func report(_ report: ConversionEngine.Report) -> Int32 {
        for url in report.outputs { print("✓ \(url.path)") }
        for failure in report.failures { print("✗ \(failure.url.lastPathComponent): \(failure.message)") }
        if let note = report.note { print(note) }
        return report.failures.isEmpty ? 0 : 1
    }
}
