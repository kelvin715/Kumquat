import AppKit
import KumquatCore
import SwiftUI

/// Header with a close button and centred title, the tool's content, and a footer bar.
struct ToolChrome<Content: View, Footer: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.inkSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 40)
            .background(WindowDragArea())
            Rectangle().fill(Theme.separator).frame(height: 1)
            content
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack { footer }
                .padding(.horizontal, 14)
                .frame(height: 50)
        }
        .background(Theme.windowGradient)
    }
}

/// Checkerboard behind transparent images.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.black.opacity(0.06)))
                }
            }
        }
        .background(Color.white.opacity(0.7))
    }
}

/// A titled window with hidden traffic lights, so the SwiftUI chrome is the whole look.
final class ToolWindow: NSWindow {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Only the header moves the window, so dragging crop handles or drawing never does.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .aqua)
        backgroundColor = .clear
        isOpaque = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// SwiftUI content over a behind-window blur, so the warm gradient reads as frosted glass.
    static func glassContent<V: View>(_ view: V) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let hosting = NSHostingView(rootView: view.ignoresSafeArea())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }
}

/// Lets the user move the window by dragging the header.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandle() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragHandle: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Opens tool windows and turns their results into toasts.
@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()
    private var windows: [ToolWindow] = []

    func open<V: View>(title: String, size: NSSize, @ViewBuilder content: (_ close: @escaping () -> Void) -> V) {
        let window = ToolWindow(size: size)
        window.title = title
        let close: () -> Void = { [weak window] in window?.close() }
        window.contentView = ToolWindow.glassContent(content(close))
        window.delegate = self

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? ToolWindow else { return }
        windows.removeAll { $0 === window }
    }

    /// Runs `work` off the main thread with a toast, then reports the saved file.
    func save(title: String, doneTitle: String, work: @escaping @Sendable () async throws -> URL) {
        let toast = ToastCenter.shared.begin(title: title, total: 1)
        let task = Task.detached(priority: .userInitiated) {
            do {
                let url = try await work()
                await MainActor.run {
                    ToastCenter.shared.succeed(toast, title: doneTitle, subtitle: url.lastPathComponent, outputs: [url])
                    AppActions.finished(outputs: [url])
                }
            } catch {
                await MainActor.run {
                    ToastCenter.shared.fail(toast, title: L("Couldn't save"), message: ConversionEngine.message(for: error))
                }
            }
        }
        toast.onCancel = { task.cancel() }
    }
}
