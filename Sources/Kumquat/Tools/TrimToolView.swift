@preconcurrency import AVFoundation
import AVKit
import KumquatCore
import SwiftUI

/// Uses AVKit's own trimming bar (the one QuickTime Player has).
struct TrimToolView: View {
    let url: URL
    let close: () -> Void

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Trim"), size: NSSize(width: 640, height: 470)) { close in
            TrimToolView(url: url, close: close)
        }
    }

    var body: some View {
        ToolChrome(title: L("Trim"), close: close) {
            TrimPlayer(url: url) { range in
                close()
                guard let range else { return }
                let url = url
                ToolWindowManager.shared.save(title: L("Trimming"), doneTitle: L("Trimmed copy saved")) {
                    try await VideoTools.trim(url, range: range)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } footer: {
            Image(systemName: "scissors").foregroundStyle(Theme.inkSecondary)
            Text(L("Drag the yellow handles, then click Trim."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
            Spacer()
        }
    }
}

struct TrimPlayer: NSViewRepresentable {
    let url: URL
    let onFinish: (CMTimeRange?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        let item = AVPlayerItem(url: url)
        view.player = AVPlayer(playerItem: item)
        context.coordinator.attach(view: view, item: item)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        coordinator.observation = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        let onFinish: (CMTimeRange?) -> Void
        var observation: NSKeyValueObservation?
        private var started = false

        init(onFinish: @escaping (CMTimeRange?) -> Void) {
            self.onFinish = onFinish
        }

        func attach(view: AVPlayerView, item: AVPlayerItem) {
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak view] item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    guard let self, let view else { return }
                    self.beginTrimming(view, item: item)
                }
            }
        }

        private func beginTrimming(_ view: AVPlayerView, item: AVPlayerItem) {
            guard !started else { return }
            guard view.window != nil, view.canBeginTrimming else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.beginTrimming(view, item: item)
                }
                return
            }
            started = true
            view.beginTrimming { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    guard result == .okButton else {
                        self.onFinish(nil)
                        return
                    }
                    let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                    let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                    self.onFinish(CMTimeRange(start: start, end: end))
                }
            }
        }
    }
}
