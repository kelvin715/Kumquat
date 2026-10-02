import CoreImage
import KumquatCore
import SwiftUI

struct EditToolView: View {
    @StateObject private var doc: ImageDocument
    let close: () -> Void

    @State private var adjustments = ImageAdjustments()
    @State private var rendered: CGImage?
    @State private var showOriginal = false
    private let context: CIContext = SharedCoreImage.context

    init(document: ImageDocument, close: @escaping () -> Void, adjustments: ImageAdjustments = ImageAdjustments()) {
        _doc = StateObject(wrappedValue: document)
        _adjustments = State(initialValue: adjustments)
        if let preview = document.preview {
            _rendered = State(initialValue: ImageAdjuster.apply(adjustments, to: preview))
        }
        self.close = close
    }

    init(url: URL, close: @escaping () -> Void) {
        self.init(document: ImageDocument(url: url, previewSize: 1200), close: close)
    }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Edit Image"), size: NSSize(width: 470, height: 720)) { close in
            EditToolView(url: url, close: close)
        }
    }

    var body: some View {
        ToolChrome(title: L("Edit Image"), close: close) {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if let image = showOriginal ? doc.preview.map(orientedOriginal) : (rendered ?? doc.preview) {
                        FittedImage(image: image)
                    } else {
                        LoadingView(error: doc.errorMessage)
                    }
                    if doc.preview != nil {
                        Text(showOriginal ? L("Original") : L("Hold to compare"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.15, pressing: { showOriginal = $0 }, perform: {})

                HStack(spacing: 6) {
                    iconButton("rotate.left", L("Rotate left")) { adjustments.quarterTurns -= 1 }
                    iconButton("rotate.right", L("Rotate right")) { adjustments.quarterTurns += 1 }
                    iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", L("Flip horizontal")) {
                        adjustments.flipHorizontal.toggle()
                    }
                    iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", L("Flip vertical")) {
                        adjustments.flipVertical.toggle()
                    }
                    Spacer()
                }

                VStack(spacing: 6) {
                    slider(L("Exposure"), \.exposure, -2...2)
                    slider(L("Contrast"), \.contrast, 0.5...1.5, neutral: 1)
                    slider(L("Saturation"), \.saturation, 0...2, neutral: 1)
                    slider(L("Vibrance"), \.vibrance, -1...1)
                    slider(L("Warmth"), \.warmth, -1...1)
                    slider(L("Highlights"), \.highlights, 0...1, neutral: 1)
                    slider(L("Shadows"), \.shadows, -1...1)
                    slider(L("Sharpness"), \.sharpness, 0...1)
                    slider(L("Vignette"), \.vignette, 0...1)
                }
            }
        } footer: {
            Button(L("Reset")) { adjustments = ImageAdjustments() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L("Save")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(doc.preview == nil || adjustments.isIdentity)
        }
        .onChange(of: doc.preview != nil) { render() }
        .onChange(of: adjustments) { render() }
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<ImageAdjustments, Double>,
                        _ range: ClosedRange<Double>, neutral: Double = 0) -> some View {
        OrangeSlider(label: label,
                     value: Binding(get: { adjustments[keyPath: keyPath] }, set: { adjustments[keyPath: keyPath] = $0 }),
                     range: range, unit: "",
                     format: { value in
                         let shown = Int(((value - neutral) * 100).rounded())
                         return shown > 0 ? "+\(shown)" : "\(shown)"
                     })
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.trackFill))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The original, but with the same rotation so the comparison lines up.
    private func orientedOriginal(_ image: CGImage) -> CGImage {
        var geometryOnly = ImageAdjustments()
        geometryOnly.quarterTurns = adjustments.quarterTurns
        geometryOnly.flipHorizontal = adjustments.flipHorizontal
        geometryOnly.flipVertical = adjustments.flipVertical
        return ImageAdjuster.apply(geometryOnly, to: image, context: context) ?? image
    }

    private func render() {
        guard let preview = doc.preview else { return }
        rendered = ImageAdjuster.apply(adjustments, to: preview, context: context)
    }

    private func save() {
        guard let full = doc.full else { return }
        let url = doc.url
        let adjustments = adjustments
        close()
        ToolWindowManager.shared.save(title: L("Saving edits"), doneTitle: L("Edits saved")) {
            guard let image = ImageAdjuster.apply(adjustments, to: full) else { throw KumquatError.encodeFailed("edit") }
            return try ImageOutput.save(image, like: url, tag: "Edited")
        }
    }
}
