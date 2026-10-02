import AppKit
import SwiftUI

/// Borderless, click-through-where-transparent panel that floats above everything and
/// never takes focus, so Finder keeps running its drag session.
final class WheelPanel: NSPanel {
    init(side: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Receives the dragged files. Drop targets are computed from the wheel geometry,
/// so the gaps between segments still count as the nearest segment.
final class WheelDropView: NSView {
    weak var controller: WheelController?
    private let hosting: NSHostingView<WheelView>

    init(model: WheelModel) {
        hosting = NSHostingView(rootView: WheelView(model: model))
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            _ = controller?.dragEntered(urls: Self.fileURLs(sender.draggingPasteboard))
        }
        return update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { _ = controller?.hover(at: nil) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return MainActor.assumeIsolated { controller?.segment(at: point) != nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let urls = Self.fileURLs(sender.draggingPasteboard)
        return MainActor.assumeIsolated { controller?.drop(at: point, urls: urls) ?? false }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { _ = controller?.dragSessionEnded() }
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let index = MainActor.assumeIsolated { controller?.hover(at: point) }
        guard index != nil else { return [] }
        // Never report a move: some sources delete their data after a "moved" drop.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
