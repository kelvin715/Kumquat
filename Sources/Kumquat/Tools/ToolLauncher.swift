import AppKit
import CoreImage
import KumquatCore
import SwiftUI

@MainActor
enum ToolLauncher {
    static func open(_ tool: ToolKind, for url: URL) {
        let kind = FileClassifier.kind(of: url)
        switch (tool, kind) {
        case (.crop, .image): CropToolView.open(url)
        case (.addBackground, .image): BackgroundToolView.open(url)
        case (.edit, .image): EditToolView.open(url)
        case (.annotate, .image): AnnotateToolView.open(url)
        case (.redact, .image): RedactToolView.open(url)
        case (.metadata, .image): ImageMetadataView.open(url)
        case (.metadata, .pdf): PDFMetadataView.open(url)
        case (.watermark, .pdf): WatermarkToolView.open(url)
        case (.trim, .video), (.trim, .audio): TrimToolView.open(url)
        default: AppActions.runInBackground(.tool(tool), on: [url])
        }
    }
}

/// One Core Image context for all previews (creating contexts is expensive).
enum SharedCoreImage {
    static let context: CIContext = {
        var options: [CIContextOption: Any] = [:]
        options[CIContextOption.cacheIntermediates] = false
        return CIContext(options: options)
    }()
}

/// Loads an image once: the full-resolution upright bitmap for saving and a smaller copy for
/// fast on-screen previews.
@MainActor
final class ImageDocument: ObservableObject {
    let url: URL
    @Published private(set) var preview: CGImage?
    @Published private(set) var pixelSize: CGSize = .zero
    @Published private(set) var errorMessage: String?
    private(set) var full: CGImage?

    /// Already-decoded image (previews and tests).
    init(url: URL, image: CGImage, previewSize: Int = 1400) {
        self.url = url
        full = image
        preview = ImageConverter.downscaled(image, maxPixel: previewSize)
        pixelSize = CGSize(width: image.width, height: image.height)
    }

    init(url: URL, previewSize: Int = 1400) {
        self.url = url
        Task.detached(priority: .userInitiated) { [url] in
            do {
                let full = try ImageIOHelpers.loadImage(url)
                let preview = ImageConverter.downscaled(full, maxPixel: previewSize)
                await MainActor.run {
                    self.full = full
                    self.preview = preview
                    self.pixelSize = CGSize(width: full.width, height: full.height)
                }
            } catch {
                await MainActor.run { self.errorMessage = ConversionEngine.message(for: error) }
            }
        }
    }

    /// Preview pixels per full-size pixel.
    var previewScale: CGFloat {
        guard let preview, pixelSize.width > 0 else { return 1 }
        return CGFloat(preview.width) / pixelSize.width
    }
}

/// Image preview fitted into the available space, reporting where it ended up.
struct FittedImage: View {
    let image: CGImage
    var onLayout: (CGRect) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fit(CGSize(width: image.width, height: image.height), in: geo.size)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .onAppear { onLayout(rect) }
                .onChange(of: rect) { onLayout(rect) }
        }
    }

    static func fit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

/// Placeholder while an image loads (or the error if it can't).
struct LoadingView: View {
    let error: String?
    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
