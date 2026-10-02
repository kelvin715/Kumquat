import AppKit
import KumquatCore

/// The menu bar item: hints, recent results, settings and quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = StatusIcon.make()
        item.button?.toolTip = "Kumquat"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: L("Hold ⇧ while dragging a file to convert it"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let tools = NSMenuItem(title: L("Hold ⌥⇧ for tools"), action: nil, keyEquivalent: "")
        tools.isEnabled = false
        menu.addItem(tools)
        menu.addItem(.separator())

        if !AppActions.recentOutputs.isEmpty {
            let title = NSMenuItem(title: L("Recent"), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for url in AppActions.recentOutputs.prefix(6) {
                let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = url
                entry.image = NSWorkspace.shared.icon(forFile: url.path)
                entry.image?.size = NSSize(width: 16, height: 16)
                entry.isEnabled = FileManager.default.fileExists(atPath: url.path)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }

        add(L("Welcome Guide…"), #selector(showWelcome), key: "")
        add(L("Settings…"), #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(L("Quit Kumquat"), #selector(quit), key: "q")
    }

    private func add(_ title: String, _ action: Selector, key: String) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showWelcome() { WelcomeWindow.show() }
    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Menu bar glyph: a citrus slice, drawn as a template image so it follows the menu bar's colour.
enum StatusIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 8.4)
            NSColor.black.set()
            let outer = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
            outer.lineWidth = 1.5
            outer.stroke()
            for i in 0..<6 {
                let angle = CGFloat(i) * .pi / 3 + .pi / 6
                let wedge = NSBezierPath()
                wedge.move(to: NSPoint(x: center.x + cos(angle) * 1.9, y: center.y + sin(angle) * 1.9))
                wedge.line(to: NSPoint(x: center.x + cos(angle) * 5.3, y: center.y + sin(angle) * 5.3))
                wedge.lineWidth = 1.2
                wedge.lineCapStyle = .round
                wedge.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2)).fill()
            // Leaf
            let leaf = NSBezierPath()
            leaf.move(to: NSPoint(x: 12.2, y: 15.2))
            leaf.curve(to: NSPoint(x: 17.2, y: 17.4), controlPoint1: NSPoint(x: 13.4, y: 17.6), controlPoint2: NSPoint(x: 15.6, y: 18.2))
            leaf.curve(to: NSPoint(x: 12.2, y: 15.2), controlPoint1: NSPoint(x: 16.4, y: 15.6), controlPoint2: NSPoint(x: 14.2, y: 14.6))
            leaf.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
