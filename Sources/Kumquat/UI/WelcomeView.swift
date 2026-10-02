import AppKit
import KumquatCore
import SwiftUI

struct WelcomeView: View {
    let close: () -> Void
    @StateObject private var formats = WheelModel()
    @StateObject private var tools = WheelModel()
    private let sample = SampleFile.ensure()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Kumquat")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text(L("Convert files right where they are — no windows, no uploads."))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(.top, 26)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .background(WindowDragArea())

            HStack(spacing: 14) {
                card(model: formats, keys: "⇧", title: L("Hold Shift while dragging"),
                     detail: L("Drop the file on a format. The converted copy is saved next to the original."))
                card(model: tools, keys: "⌥ ⇧", title: L("Hold Option + Shift"),
                     detail: L("Tools for the file type: compress, crop, add a background, redact and more."))
            }
            .padding(.horizontal, 22)

            HStack(spacing: 16) {
                if let sample {
                    DraggableFile(url: sample)
                        .frame(width: 96, height: 96)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Try it now"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(L("Start dragging the sample picture, press ⇧ Shift, then drop it on JPG or WEBP. Click the notification to see the result."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.35)))
            .padding(.horizontal, 22)
            .padding(.top, 14)

            HStack {
                Image(systemName: "menubar.arrow.up.rectangle")
                Text(L("Kumquat lives in the menu bar. Everything stays on your Mac."))
                Spacer()
                Button(L("Get Started")) { close() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 600)
        .background(Theme.windowGradient)
        .onAppear(perform: setUpPreviews)
    }

    private func card(model: WheelModel, keys: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            WheelView(model: model)
                .scaleEffect(170 / model.diameter)
                .frame(width: 170, height: 170)
            HStack(spacing: 6) {
                Text(keys)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.7)))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.3)))
    }

    private func setUpPreviews() {
        formats.items = [OutputFormat.png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx]
            .map { WheelItem(action: .convert($0), title: $0.title, symbol: nil) }
        formats.idleText = "1.2 MB"
        formats.hovered = 1
        formats.isPresented = true
        tools.items = [ToolKind.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact]
            .map { WheelItem(action: .tool($0), title: L10n.title(for: .tool($0)), symbol: $0.symbolName) }
        tools.idleText = "1.2 MB"
        tools.hovered = 5
        tools.isPresented = true
    }
}

@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = ToolWindow(size: NSSize(width: 600, height: 560))
            w.level = .normal
            let close: () -> Void = { window?.close() }
            let view = WelcomeView(close: {
                AppSettings.shared.hasSeenWelcome = true
                close()
            })
            let size = NSHostingView(rootView: view).fittingSize
            w.contentView = ToolWindow.glassContent(view)
            w.setContentSize(size)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A file icon that can be dragged out like a Finder item.
struct DraggableFile: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DraggableFileView { DraggableFileView(url: url) }
    func updateNSView(_ nsView: DraggableFileView, context: Context) {}
}

final class DraggableFileView: NSView, NSDraggingSource {
    let url: URL
    private var dragging = false
    private lazy var icon: NSImage = {
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        return image
    }()

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 64
        let rect = NSRect(x: (bounds.width - side) / 2, y: bounds.height - side - 4, width: side, height: side)
        let size = icon.size
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let drawRect = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        icon.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
        let name = url.lastPathComponent as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(Theme.ink),
        ]
        let textSize = name.size(withAttributes: attributes)
        name.draw(at: NSPoint(x: (bounds.width - textSize.width) / 2, y: 6), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !dragging else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let side: CGFloat = 64
        item.setDraggingFrame(NSRect(x: (bounds.width - side) / 2, y: bounds.height - side - 4, width: side, height: side),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
    }
}

/// A colourful sample picture to practise on, kept in Application Support.
enum SampleFile {
    static func ensure() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Kumquat/Samples", isDirectory: true)
        let url = dir.appendingPathComponent("Kumquat Sample.png")
        if fm.fileExists(atPath: url.path) { return url }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = 1200, h = 800
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        GradientPreset.all[0].draw(in: ctx, rect: CGRect(x: 0, y: 0, width: w, height: h))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let title = "Hello from Kumquat" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 86, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (CGFloat(w) - size.width) / 2, y: (CGFloat(h) - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.current = previous
        guard let image = ctx.makeImage(), (try? ImageIOHelpers.write(image, to: url, type: .png)) != nil else { return nil }
        return url
    }
}
