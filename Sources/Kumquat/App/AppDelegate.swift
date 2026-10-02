import AppKit
import KumquatCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dragMonitor = DragMonitor()
    private lazy var wheel = WheelController {
        ActionCatalog(capabilities: AppSettings.shared.capabilities)
    }
    private var statusItem: StatusItemController?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        dragMonitor.onDragStarted = { [unowned self] urls in wheel.dragStarted(urls: urls) }
        dragMonitor.onModifiersChanged = { [unowned self] flags in wheel.modifiersChanged(flags) }
        dragMonitor.onPointerMoved = { [unowned self] point in wheel.pointerMoved(to: point) }
        dragMonitor.onDragEnded = { [unowned self] in wheel.dragEnded() }
        wheel.onAction = { action, urls in AppActions.perform(action, on: urls) }
        dragMonitor.start()

        statusItem = StatusItemController()
        // Keep the drag monitor responsive while Kumquat sits in the background (no App Nap),
        // without stopping the Mac from sleeping.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                        reason: "Watching for file drags")

        if !AppSettings.shared.hasSeenWelcome {
            WelcomeWindow.show()
        }
    }

    /// Opening the app again (e.g. from Launchpad) brings up Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
