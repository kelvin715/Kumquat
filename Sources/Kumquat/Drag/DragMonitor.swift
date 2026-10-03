import AppKit

/// Notices file drags anywhere on screen (Finder, the Desktop, other apps) without needing
/// Accessibility permission:
///  - global mouse monitors tell us when the left button goes down / drags / comes up;
///  - the drag pasteboard's change count tells us a drag session has started, and with what;
///  - while a drag is live, modifier keys and the button state are polled (~60 Hz), which
///    works even where key events aren't delivered.
@MainActor
final class DragMonitor {
    var onDragStarted: (([URL]) -> Void)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onPointerMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private(set) var isDragging = false
    private(set) var draggedURLs: [URL] = []

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var baselineChangeCount = 0
    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastFlags: NSEvent.ModifierFlags = []
    private let relevantFlags: NSEvent.ModifierFlags = [.shift, .option, .command, .control]

    func start() {
        guard monitors.isEmpty else { return }
        baselineChangeCount = dragPasteboard.changeCount
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Drags that start inside Kumquat's own windows (e.g. the sample file in the welcome window).
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown { self?.mouseDown() } else { self?.tick() }
            }
            return event
        }
        monitors = [down, dragged, up, flags, local].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopTimer()
    }

    /// Our own drag sources call this, because AppKit runs their drag loop modally.
    func beginInternalDrag() {
        mouseDown()
    }

    private func mouseDown() {
        if isDragging { finishDrag() }
        baselineChangeCount = dragPasteboard.changeCount
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes so it keeps firing during event tracking (our own drags, menus).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown {
            stopTimer()
            if isDragging { finishDrag() }
            return
        }
        if timer == nil { startTimer() }
        if !isDragging { detectDragStart() }
        guard isDragging else { return }
        let flags = NSEvent.modifierFlags.intersection(relevantFlags)
        if flags != lastFlags {
            lastFlags = flags
            onModifiersChanged?(flags)
        }
        onPointerMoved?(NSEvent.mouseLocation)
    }

    private func detectDragStart() {
        let count = dragPasteboard.changeCount
        guard count != baselineChangeCount else { return }
        baselineChangeCount = count
        let urls = (dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // If the system won't let a background app read the files, the type list still says
        // it's a file drag; the wheel then learns the files from its own drop view.
        let isFileDrag = !urls.isEmpty || (dragPasteboard.types?.contains(.fileURL) ?? false)
        guard isFileDrag else { return } // text, images from a browser, etc.
        isDragging = true
        draggedURLs = urls
        lastFlags = []
        Log.drag.debug("File drag started (\(urls.count) readable)")
        onDragStarted?(urls)
        let flags = NSEvent.modifierFlags.intersection(relevantFlags)
        if !flags.isEmpty {
            lastFlags = flags
            onModifiersChanged?(flags)
        }
    }

    private func finishDrag() {
        isDragging = false
        draggedURLs = []
        lastFlags = []
        onDragEnded?()
    }
}
