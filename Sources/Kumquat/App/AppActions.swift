import AppKit
import KumquatCore

/// Routes a dropped action: editing tools open a window, everything else runs in the background
/// with a progress toast.
@MainActor
enum AppActions {
    static var recentOutputs: [URL] = []
    static var onRecentsChanged: (() -> Void)?

    static func perform(_ action: WheelAction, on urls: [URL]) {
        guard let first = urls.first else { return }
        let kind = FileClassifier.kind(of: first)
        if case .tool(let tool) = action, ActionCatalog.isInteractive(tool, kind: kind, fileCount: urls.count) {
            ToolLauncher.open(tool, for: first)
            return
        }
        runInBackground(action, on: urls)
    }

    static func runInBackground(_ action: WheelAction, on urls: [URL]) {
        let settings = AppSettings.shared
        let engine = ConversionEngine(capabilities: settings.capabilities, options: settings.conversionOptions)
        let total = action == .tool(.merge) ? 1 : urls.count
        let toast = ToastCenter.shared.begin(title: progressTitle(for: action), total: total)
        let task = Task.detached(priority: .userInitiated) {
            let report = await engine.run(action, on: urls) { done, total in
                Task { @MainActor in ToastCenter.shared.update(toast, done: done, total: total) }
            }
            await MainActor.run { complete(report, toast: toast, action: action, total: total) }
        }
        toast.onCancel = { task.cancel() }
    }

    private static func complete(_ report: ConversionEngine.Report, toast: ToastItem, action: WheelAction, total: Int) {
        if report.outputs.isEmpty {
            let message = report.failures.first?.message ?? L("Nothing was saved.")
            ToastCenter.shared.fail(toast, title: L("Couldn't finish"), message: message)
            if AppSettings.shared.playSound { NSSound(named: "Funk")?.play() }
            return
        }
        let title = report.outputs.count == 1
            ? report.outputs[0].lastPathComponent
            : L10n.progress(report.outputs.count, of: total)
        var subtitle = L("Saved next to the original")
        if let percent = report.savedPercent {
            subtitle = L10n.usesChinese ? "体积减少 \(percent)%" : "\(percent)% smaller"
        }
        if !report.failures.isEmpty {
            subtitle = "\(report.failures.count) " + L("failed") + " — " + report.failures[0].message
        }
        ToastCenter.shared.succeed(toast, title: title, subtitle: subtitle, outputs: report.outputs)
        finished(outputs: report.outputs)
    }

    /// Bookkeeping shared by background jobs and tool windows.
    static func finished(outputs: [URL]) {
        recentOutputs = Array((outputs + recentOutputs).prefix(8))
        onRecentsChanged?()
        if AppSettings.shared.playSound { NSSound(named: "Pop")?.play() }
        if AppSettings.shared.revealAfterSaving { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    static func progressTitle(for action: WheelAction) -> String {
        switch action {
        case .convert(let format):
            return L10n.usesChinese ? "正在转换为 \(format.title)" : "Converting to \(format.title)"
        case .tool(let tool):
            switch tool {
            case .compress: return L("Compressing")
            case .rotate: return L("Rotating")
            case .split: return L("Splitting pages")
            case .merge: return L("Merging")
            case .mute: return L("Removing audio")
            case .snapshot: return L("Saving a frame")
            case .metadata: return L("Removing metadata")
            default: return L("Working")
            }
        }
    }
}
