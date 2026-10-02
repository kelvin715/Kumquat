import AppKit
import KumquatCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var capabilities = AppSettings.shared.capabilities
    @StateObject private var preview = WheelModel()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    WheelView(model: preview)
                        .frame(width: 150, height: 150)
                        .scaleEffect(150 / preview.diameter)
                        .frame(width: 150, height: 150)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Drag a file and hold ⇧ Shift"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("A wheel of formats appears around the pointer. Drop the file on one and the converted copy is saved next to the original."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(L("Hold ⌥ Option + ⇧ Shift for tools: compress, crop, add a background and more."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent(L("Wheel size")) {
                    Slider(value: $settings.wheelDiameter, in: 220...340, step: 10)
                        .frame(width: 220)
                }
            }

            Section(L("General")) {
                Picker(L("Language"), selection: $settings.language) {
                    Text(L("System")).tag(AppSettings.Language.system)
                    Text("English").tag(AppSettings.Language.english)
                    Text("简体中文").tag(AppSettings.Language.chinese)
                }
                Toggle(L("Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { LoginItem.set(launchAtLogin) }
                Toggle(L("Play a sound when done"), isOn: $settings.playSound)
                Toggle(L("Haptic feedback on trackpads"), isOn: $settings.hapticFeedback)
                Toggle(L("Show results in Finder"), isOn: $settings.revealAfterSaving)
            }

            Section(L("Quality")) {
                LabeledContent(L("JPG / HEIC quality")) {
                    HStack {
                        Slider(value: $settings.imageQuality, in: 0.5...1, step: 0.05).frame(width: 180)
                        Text("\(Int(settings.imageQuality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent(L("Compress tool quality")) {
                    HStack {
                        Slider(value: $settings.compressQuality, in: 0.3...0.9, step: 0.05).frame(width: 180)
                        Text("\(Int(settings.compressQuality * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker(L("PDF to image resolution"), selection: $settings.pdfDPI) {
                    Text("150 dpi").tag(150.0)
                    Text("300 dpi").tag(300.0)
                    Text("600 dpi").tag(600.0)
                }
                Toggle(L("Lossless WebP"), isOn: $settings.webpLossless)
                    .disabled(capabilities.cwebpURL == nil)
                    .help(capabilities.cwebpURL == nil
                          ? L("Kumquat's built-in WebP encoder is always lossless. Install cwebp for smaller lossy files.")
                          : "")
            }

            Section(L("Optional helpers")) {
                Toggle(L("Use Homebrew tools when installed"), isOn: $settings.useExternalTools)
                    .onChange(of: settings.useExternalTools) { capabilities = settings.capabilities }
                helperRow("ffmpeg", capabilities.ffmpegURL, L("MP3, WebM, MKV and other formats"))
                helperRow("cwebp", capabilities.cwebpURL, L("Smaller lossy WebP"))
                if capabilities.ffmpegURL == nil || capabilities.cwebpURL == nil {
                    HStack {
                        Text("brew install ffmpeg webp")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button(L("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install ffmpeg webp", forType: .string)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Kumquat \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Welcome Guide")) { WelcomeWindow.show() }
                    Link(L("Source on GitHub"), destination: URL(string: "https://github.com/kelvin715/Kumquat")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            preview.items = ["DOCX", "JPG", "PNG", "TXT"].compactMap { OutputFormat(rawValue: $0.lowercased()) }
                .map { WheelItem(action: .convert($0), title: $0.title, symbol: nil) }
            preview.idleText = "1.1 MB"
            preview.hovered = 1
            preview.isPresented = true
        }
    }

    private func helperRow(_ name: String, _ url: URL?, _ purpose: String) -> some View {
        HStack {
            Image(systemName: url == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(url == nil ? Color.secondary : Theme.tangerine)
            Text(name).font(.system(size: 12, weight: .medium, design: .monospaced))
            Text("— " + purpose).foregroundStyle(.secondary)
            Spacer()
            Text(url?.path ?? L("Not installed"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.title = L("Kumquat Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum LoginItem {
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Kumquat: couldn't change login item: \(error.localizedDescription)")
        }
    }
}
