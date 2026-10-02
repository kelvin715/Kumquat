import AppKit
import SwiftUI

/// One running or finished job, shown as a small card at the bottom of the screen.
@MainActor
final class ToastItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case succeeded
        case failed
    }

    let id = UUID()
    @Published var title: String
    @Published var subtitle: String
    @Published var progress: Double
    @Published var state: State = .running
    var outputs: [URL] = []
    var onCancel: (() -> Void)?

    init(title: String, subtitle: String = "", progress: Double = 0) {
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published private(set) var items: [ToastItem] = []
    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastStack>?

    func begin(title: String, total: Int) -> ToastItem {
        let item = ToastItem(title: title, subtitle: L10n.progress(0, of: total))
        items.append(item)
        if items.count > 4 { items.removeFirst() }
        present()
        return item
    }

    func update(_ item: ToastItem, done: Int, total: Int) {
        item.progress = total > 0 ? Double(done) / Double(total) : 0
        item.subtitle = L10n.progress(done, of: total)
    }

    func succeed(_ item: ToastItem, title: String, subtitle: String, outputs: [URL]) {
        item.state = .succeeded
        item.progress = 1
        item.title = title
        item.subtitle = subtitle
        item.outputs = outputs
        item.onCancel = nil
        dismiss(item, after: 3.2)
    }

    func fail(_ item: ToastItem, title: String, message: String) {
        item.state = .failed
        item.title = title
        item.subtitle = message
        item.onCancel = nil
        dismiss(item, after: 6)
    }

    func dismiss(_ item: ToastItem, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.items.removeAll { $0.id == item.id }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if self.items.isEmpty { self.panel?.orderOut(nil) } else { self.layout() }
            }
        }
    }

    func reveal(_ item: ToastItem) {
        guard !item.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(item.outputs)
        dismiss(item)
    }

    private func present() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: ToastStack(center: self))
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
        }
        layout()
        panel?.orderFrontRegardless()
    }

    private func layout() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = max(size.width, 320)
        let height = max(size.height, 10)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 28, width: width, height: height), display: true)
    }

    fileprivate func contentChanged() {
        DispatchQueue.main.async { self.layout() }
    }
}

struct ToastStack: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.items) { item in
                ToastCard(item: item)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(width: 320)
        .onChange(of: center.items.count) { center.contentChanged() }
    }
}

struct ToastCard: View {
    @ObservedObject var item: ToastItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if item.state == .running { item.onCancel?() }
                    ToastCenter.shared.dismiss(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.state == .running ? L("Cancel") : L("Close"))

                Group {
                    switch item.state {
                    case .running: ProgressView().controlSize(.mini)
                    case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.tangerine)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.tangerineDeep)
                    }
                }
                .frame(width: 14)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            Text(item.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(item.state == .failed ? 3 : 1)
                .padding(.leading, 46)
            if item.state == .running {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.tangerine)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Theme.hex(0xFFE9D6, 0.97), Theme.hex(0xFFD6BD, 0.97)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture { ToastCenter.shared.reveal(item) }
        .help(item.state == .succeeded ? L("Click to show in Finder") : "")
    }
}
