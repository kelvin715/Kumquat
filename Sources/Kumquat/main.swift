import AppKit

// `Kumquat convert …` and friends run headless; anything else starts the menu bar app.
if CommandLineTool.shouldHandle(CommandLine.arguments) {
    let status = await CommandLineTool.run(CommandLine.arguments)
    exit(status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
