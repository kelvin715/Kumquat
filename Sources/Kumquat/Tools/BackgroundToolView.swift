import AppKit
import KumquatCore
import SwiftUI

struct BackgroundToolView: View {
    @StateObject private var doc: ImageDocument
    let close: () -> Void

    @State private var params = BackgroundParams(fill: .gradient(GradientPreset.all[0]), padding: 0, cornerRadius: 0,
                                                 shadow: 0, ratio: .auto)
    @State private var customColor = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.95)
    @State private var backgroundImage: CGImage?
    @State private var rendered: CGImage?

    init(document: ImageDocument, close: @escaping () -> Void) {
        _doc = StateObject(wrappedValue: document)
        if document.pixelSize.width > 0, let preview = document.preview {
            let params = BackgroundParams.defaults(for: document.pixelSize)
            _params = State(initialValue: params)
            _rendered = State(initialValue: BackgroundComposer.compose(
                preview, params: params.scaled(by: Double(document.previewScale))))
        }
        self.close = close
    }

    init(url: URL, close: @escaping () -> Void) {
        self.init(document: ImageDocument(url: url, previewSize: 900), close: close)
    }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Add BG"), size: NSSize(width: 470, height: 690)) { close in
            BackgroundToolView(url: url, close: close)
        }
    }

    private var size: CGSize { doc.pixelSize }

    var body: some View {
        ToolChrome(title: L("Add BG"), close: close) {
            VStack(spacing: 14) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.22)))
                swatches
                VStack(spacing: 8) {
                    OrangeSlider(label: L("Padding"), value: $params.padding, range: 0...max(1, Double(max(size.width, size.height)) * 0.5))
                    OrangeSlider(label: L("Corners"), value: $params.cornerRadius, range: 0...max(1, Double(min(size.width, size.height)) * 0.25))
                    OrangeSlider(label: L("Shadow"), value: $params.shadow, range: 0...max(1, Double(max(size.width, size.height)) * 0.06))
                }
                HStack {
                    Text(L("Ratio")).font(.system(size: 11)).foregroundStyle(Theme.ink)
                    Spacer()
                    OrangeSegmented(options: CanvasRatio.allCases.map { ($0, $0 == .auto ? L("Auto") : $0.rawValue) },
                                    selection: $params.ratio)
                }
            }
        } footer: {
            Button(L("Reset")) { reset() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L("Save with Background")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(doc.preview == nil)
        }
        .onChange(of: doc.pixelSize) { reset() }
        .onChange(of: params) { render() }
        .onChange(of: backgroundImage) { render() }
    }

    @ViewBuilder private var preview: some View {
        if let rendered {
            FittedImage(image: rendered)
                .padding(10)
        } else {
            LoadingView(error: doc.errorMessage)
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                FieldLabel(text: L("Background"))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(GradientPreset.all) { preset in
                            Swatch(selected: params.fill == .gradient(preset), action: { params.fill = .gradient(preset) }) {
                                GradientSwatch(preset: preset)
                            }
                        }
                        Swatch(selected: isImageFill, action: chooseImage) {
                            ZStack {
                                Color.white.opacity(0.6)
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                        .help(L("Use a picture as the background"))
                    }
                    HStack(spacing: 2) {
                        ForEach(GradientPreset.solids, id: \.self) { color in
                            Swatch(selected: params.fill == .solid(color), action: { params.fill = .solid(color) }) {
                                Color(nsColor: color.nsColor)
                            }
                        }
                        if RenderContext.isOffscreen {
                            Capsule().fill(customColor).frame(width: 34, height: 18).padding(.leading, 4)
                        } else {
                            ColorPicker("", selection: $customColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 34)
                                .help(L("Custom colour"))
                                .onChange(of: customColor) {
                                    let picked: NSColor = NSColor(customColor)
                                    if let c = picked.usingColorSpace(NSColorSpace.sRGB) {
                                        let rgba = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                                        params.fill = .solid(rgba)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private var isImageFill: Bool {
        if case .image = params.fill { return true }
        return false
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = L("Choose a background picture")
        guard panel.runModal() == .OK, let url = panel.url, let image = try? ImageIOHelpers.loadImage(url, maxPixelSize: 6000) else { return }
        backgroundImage = image
        params.fill = .image(url)
    }

    private func reset() {
        guard size.width > 0 else { return }
        params = BackgroundParams.defaults(for: size)
        render()
    }

    private func render() {
        guard let preview = doc.preview else { return }
        let scaled = params.scaled(by: Double(doc.previewScale))
        let bg = backgroundImage.map { ImageConverter.downscaled($0, maxPixel: 1200) }
        rendered = BackgroundComposer.compose(preview, params: scaled, backgroundImage: bg)
    }

    private func save() {
        guard let full = doc.full else { return }
        let url = doc.url
        let params = params
        let bg = backgroundImage
        close()
        ToolWindowManager.shared.save(title: L("Adding background"), doneTitle: L("Background added")) {
            guard let image = BackgroundComposer.compose(full, params: params, backgroundImage: bg) else {
                throw KumquatError.encodeFailed("background")
            }
            return try ImageOutput.save(image, like: url, tag: "With Background", forcePNG: true)
        }
    }
}

/// Small rendering of a gradient preset for its swatch.
struct GradientSwatch: View {
    let preset: GradientPreset

    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                preset.draw(in: cg, rect: CGRect(origin: .zero, size: size))
            }
        }
    }
}
