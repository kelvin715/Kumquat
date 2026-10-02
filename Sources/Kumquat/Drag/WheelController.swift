import AppKit
import KumquatCore

/// Shows the wheel around the pointer while a file drag is in progress and turns a drop
/// on a segment into an action.
@MainActor
final class WheelController {
    let model = WheelModel()
    var catalogProvider: () -> ActionCatalog
    var onAction: ((WheelAction, [URL]) -> Void)?

    private(set) var isShowing = false
    private var panel: WheelPanel?
    private var dropView: WheelDropView?
    private var urls: [URL] = []
    private var center: NSPoint = .zero
    private var dropPerformed = false
    private let margin: CGFloat = 36

    init(catalogProvider: @escaping () -> ActionCatalog) {
        self.catalogProvider = catalogProvider
    }

    // MARK: - Drag monitor events

    func dragStarted(urls: [URL]) {
        self.urls = urls
        dropPerformed = false
    }

    /// Shift shows the format wheel, Option+Shift the tool wheel. Letting go of the keys keeps
    /// the wheel up, so the drop doesn't race the fingers.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard flags.contains(.shift), !flags.contains(.command), !flags.contains(.control) else { return }
        let mode: WheelMode = flags.contains(.option) ? .tools : .formats
        if isShowing {
            if model.mode != mode { setMode(mode) }
        } else {
            show(mode: mode, at: NSEvent.mouseLocation)
        }
    }

    /// Walking far away from the wheel dismisses it so the drag can carry on normally.
    func pointerMoved(to point: NSPoint) {
        guard isShowing else { return }
        let distance = hypot(point.x - center.x, point.y - center.y)
        if distance > model.diameter / 2 + 150 { hide() }
    }

    func dragEnded() {
        hide()
    }

    // MARK: - Drop view events

    func dragEntered(urls: [URL]) {
        guard !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        guard isShowing else { return }
        model.idleText = idleText()
        setMode(model.mode)
        if model.items.isEmpty { hide() } // nothing Kumquat can do with these files
    }

    func segment(at point: CGPoint) -> Int? {
        guard let dropView, isShowing, !model.items.isEmpty else { return nil }
        let geometry = WheelGeometry(count: model.items.count, radius: model.diameter / 2,
                                     center: CGPoint(x: dropView.bounds.midX, y: dropView.bounds.midY))
        if case .segment(let index) = geometry.hitTest(point) { return index }
        return nil
    }

    @discardableResult
    func hover(at point: CGPoint?) -> Int? {
        let index = point.flatMap(segment(at:))
        if index != model.hovered {
            model.hovered = index
            if index != nil && AppSettings.shared.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return index
    }

    func drop(at point: CGPoint, urls dropped: [URL]) -> Bool {
        guard let index = segment(at: point), model.items.indices.contains(index) else { return false }
        let action = model.items[index].action
        let files = dropped.isEmpty ? urls : dropped
        guard !files.isEmpty else { return false }
        dropPerformed = true
        model.chosen = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in self?.hide() }
        // Let the drag session finish before any window opens.
        DispatchQueue.main.async { [weak self] in self?.onAction?(action, files) }
        return true
    }

    func dragSessionEnded() {
        if !dropPerformed { hide() }
    }

    // MARK: - Presentation

    /// Shows the wheel for an explicit set of files (used by the welcome window demo and previews).
    func show(urls: [URL], mode: WheelMode, at point: NSPoint) {
        self.urls = urls
        show(mode: mode, at: point)
    }

    private func items(for mode: WheelMode) -> [WheelItem] {
        catalogProvider().actions(for: urls, mode: mode).map {
            WheelItem(action: $0, title: L10n.title(for: $0), symbol: $0.symbolName)
        }
    }

    private func show(mode: WheelMode, at point: NSPoint) {
        let items = items(for: mode)
        // With no files known yet (see DragMonitor) show an empty wheel; the drop view fills it in.
        guard !items.isEmpty || urls.isEmpty else { return }
        model.mode = mode
        model.items = items
        model.hovered = nil
        model.chosen = nil
        model.diameter = CGFloat(AppSettings.shared.wheelDiameter)
        model.idleText = idleText()

        let panel = ensurePanel()
        let side = model.diameter + margin * 2
        var frame = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let bounds = screen.frame
            frame.origin.x = min(max(frame.origin.x, bounds.minX - margin), bounds.maxX - side + margin)
            frame.origin.y = min(max(frame.origin.y, bounds.minY - margin), bounds.maxY - side + margin)
        }
        panel.setFrame(frame, display: false)
        center = NSPoint(x: frame.midX, y: frame.midY)
        model.isPresented = false
        panel.orderFrontRegardless()
        isShowing = true
        dropPerformed = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing else { return }
            self.model.isPresented = true
        }
    }

    private func setMode(_ mode: WheelMode) {
        let items = items(for: mode)
        guard !items.isEmpty else {
            model.items = []
            return
        }
        model.mode = mode
        model.hovered = nil
        model.items = items
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        model.isPresented = false
        model.hovered = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel?.orderOut(nil)
            self.model.chosen = nil
        }
    }

    private func ensurePanel() -> WheelPanel {
        let side = CGFloat(AppSettings.shared.wheelDiameter) + margin * 2
        if let panel { return panel }
        let panel = WheelPanel(side: side)
        let view = WheelDropView(model: model)
        view.controller = self
        panel.contentView = view
        self.panel = panel
        dropView = view
        return panel
    }

    /// For the self-test.
    var dropViewForTesting: WheelDropView? { dropView }
    var panelForTesting: WheelPanel? { panel }

    private func idleText() -> String {
        if urls.isEmpty { return "…" }
        if urls.count == 1 {
            return ByteCountFormatter.string(fromByteCount: FileClassifier.fileSize(of: urls[0]), countStyle: .file)
        }
        return L10n.fileCount(urls.count)
    }
}
