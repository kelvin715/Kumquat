import AppKit
import KumquatCore

/// `Kumquat self-test`: drives the real wheel panel and drop view with a simulated drag
/// session, checking hover, mode switching and drop routing without a mouse.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "✓ \(message)" : "✗ \(message)")
            if !condition { failures += 1 }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kumquat-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("Sample.png")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        try? ImageIOHelpers.write(ctx.makeImage()!, to: png, type: .png)

        let wheel = WheelController { ActionCatalog(capabilities: Capabilities.detect(useExternalTools: false)) }
        var received: (WheelAction, [URL])?
        wheel.onAction = { received = ($0, $1) }

        // A drag starts; nothing shows until Shift is pressed.
        wheel.dragStarted(urls: [png])
        check(!wheel.isShowing, "wheel stays hidden while dragging without Shift")
        wheel.modifiersChanged([.option])
        check(!wheel.isShowing, "Option alone does not open a wheel")

        wheel.modifiersChanged([.shift])
        check(wheel.isShowing, "Shift opens the wheel")
        check(wheel.model.mode == .formats, "Shift shows formats")
        let titles = wheel.model.items.map(\.title)
        check(titles.first == "JPG" && !titles.contains("PNG"), "PNG source offers JPG first and not PNG (\(titles.joined(separator: " ")))")
        check(wheel.panelForTesting?.isVisible == true, "panel is on screen")
        check(wheel.panelForTesting?.level == .popUpMenu, "panel floats above other windows")

        guard let view = wheel.dropViewForTesting else {
            print("✗ no drop view")
            return false
        }
        view.layoutSubtreeIfNeeded()
        let geometry = WheelGeometry(count: wheel.model.items.count, radius: wheel.model.diameter / 2,
                                     center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kumquat.selftest.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([png as NSURL])

        var keepAlive: [AnyObject] = []
        func drag(to point: CGPoint) -> NSDraggingInfo {
            let fake = FakeDraggingInfo(location: view.convert(point, to: nil), pasteboard: pasteboard)
            keepAlive.append(fake)
            return fake.asDraggingInfo
        }

        // Hover each segment.
        var hoverOK = true
        for index in 0..<geometry.count {
            let op = view.draggingUpdated(drag(to: geometry.labelCenter(of: index)))
            if op != .copy || wheel.model.hovered != index { hoverOK = false }
        }
        check(hoverOK, "every segment highlights and accepts a copy drop")
        check(wheel.model.centerText == wheel.model.items[geometry.count - 1].title, "centre pill names the hovered format")

        // The gap between two segments still belongs to the nearest one.
        let between = geometry.point(radius: geometry.labelRadius, angle: geometry.centerAngle(of: 0) + geometry.step * 0.49)
        _ = view.draggingUpdated(drag(to: between))
        check(wheel.model.hovered == 0, "gap between segments snaps to the nearest segment")

        // The centre well is "no action".
        let centerOp = view.draggingUpdated(drag(to: geometry.center))
        check(centerOp == [] && wheel.model.hovered == nil, "centre well rejects the drop")
        check(wheel.model.centerText == wheel.model.idleText, "centre pill shows the file size when idle (\(wheel.model.idleText))")

        // Option+Shift switches to tools.
        wheel.modifiersChanged([.shift, .option])
        check(wheel.model.mode == .tools && wheel.model.items.count == 7, "Option+Shift switches to the 7 image tools")
        check(wheel.model.items.map(\.action) == [ToolKind.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact].map { .tool($0) },
              "tools are in the reference order")
        // Releasing the keys keeps the wheel up.
        wheel.modifiersChanged([])
        check(wheel.isShowing, "releasing the keys keeps the wheel open")
        wheel.modifiersChanged([.shift])
        check(wheel.model.mode == .formats, "Shift again returns to formats")

        // Drop on WEBP.
        guard let webp = wheel.model.items.firstIndex(where: { $0.action == .convert(.webp) }) else {
            print("✗ no WEBP segment")
            return false
        }
        let target = drag(to: geometry.labelCenter(of: webp))
        _ = view.draggingEntered(target)
        // macOS reports the mouse-up before it delivers the drop to the wheel.
        wheel.dragEnded()
        check(wheel.isShowing, "wheel stays live between the mouse-up and the drop")
        check(view.prepareForDragOperation(target), "prepare accepts a drop that arrives after the mouse-up")
        check(view.performDragOperation(target), "drop on WEBP is performed")
        view.draggingEnded(target)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(received?.0 == .convert(.webp) && received?.1 == [png], "drop routes .convert(webp) with the dragged file")
        check(!wheel.isShowing, "wheel hides after the drop")

        // A release with no drop on the wheel closes it shortly afterwards.
        wheel.dragStarted(urls: [png])
        wheel.modifiersChanged([.shift])
        wheel.dragEnded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        check(!wheel.isShowing, "wheel closes after a release elsewhere")

        // Walking far away dismisses the wheel.
        wheel.dragStarted(urls: [png])
        wheel.modifiersChanged([.shift])
        let origin = wheel.panelForTesting.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        wheel.pointerMoved(to: NSPoint(x: origin.x + 600, y: origin.y))
        check(!wheel.isShowing, "moving far away dismisses the wheel")

        // Files unknown at drag start (pasteboard unreadable): empty wheel, filled in on entry.
        wheel.dragStarted(urls: [])
        wheel.modifiersChanged([.shift])
        check(wheel.isShowing && wheel.model.items.isEmpty && wheel.model.centerText == "…", "unreadable drag shows a pending wheel")
        _ = view.draggingEntered(drag(to: geometry.center))
        // The exact list depends on the Mac (e.g. AVIF needs macOS 14+ ImageIO support or ffmpeg).
        let expected = ActionCatalog(capabilities: Capabilities.detect(useExternalTools: false)).formats(for: png).count
        check(!wheel.model.items.isEmpty && wheel.model.items.count == expected,
              "drop view fills in the formats from the dragging pasteboard")
        wheel.dragEnded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // Unsupported files never open a wheel.
        let unknown = dir.appendingPathComponent("archive.xyz")
        FileManager.default.createFile(atPath: unknown.path, contents: Data([1, 2, 3]))
        wheel.dragStarted(urls: [unknown])
        wheel.modifiersChanged([.shift])
        check(!wheel.isShowing, "unsupported file types don't open a wheel")
        wheel.dragEnded()

        print(failures == 0 ? "All self-tests passed." : "\(failures) self-test(s) failed.")
        return failures == 0
    }
}

/// The three NSDraggingInfo members WheelDropView reads. Declaring only these keeps the
/// self-test independent of SDK differences in the full protocol.
@objc private protocol DraggingInfoSubset: NSObjectProtocol {
    var draggingLocation: NSPoint { get }
    var draggingPasteboard: NSPasteboard { get }
    var draggingSourceOperationMask: NSDragOperation { get }
}

private final class FakeDraggingInfo: NSObject, DraggingInfoSubset {
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }

    init(location: NSPoint, pasteboard: NSPasteboard) {
        draggingLocation = location
        draggingPasteboard = pasteboard
    }

    /// Objective-C protocol calls are sent as messages, so the object can stand in for NSDraggingInfo.
    var asDraggingInfo: NSDraggingInfo { unsafeBitCast(self as AnyObject, to: NSDraggingInfo.self) }
}
