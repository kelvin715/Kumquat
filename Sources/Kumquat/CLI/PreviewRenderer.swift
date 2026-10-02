import AppKit
import KumquatCore
import SwiftUI

/// Renders the wheel and tool windows off-screen (for README screenshots and visual checks).
@MainActor
enum PreviewRenderer {
    static func renderAll(to folder: URL) -> Bool {
        RenderContext.isOffscreen = true
        defer { RenderContext.isOffscreen = false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = samplePage()
        let pageURL = folder.appendingPathComponent("Page 001.jpg")
        let doc = { ImageDocument(url: pageURL, image: page) }
        var ok = true

        func save<V: View>(_ name: String, _ view: V) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  (try? ImageIOHelpers.write(image, to: folder.appendingPathComponent(name), type: .png)) != nil
            else {
                print("✗ \(name)")
                ok = false
                return
            }
            print("✓ \(name)")
        }

        save("wheel-pdf-formats.png", wheel(formats: [.docx, .jpg, .png, .txt], hovered: 0, idle: "1.1 MB"))
        save("wheel-image-formats.png", wheel(formats: [.png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx], hovered: 3, idle: "1.2 MB"))
        save("wheel-image-tools.png", wheel(tools: [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact], hovered: nil, idle: "1.2 MB"))
        save("wheel-image-tools-hover.png", wheel(tools: [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact], hovered: 5, idle: "1.2 MB"))
        save("wheel-video-tools.png", wheel(tools: [.compress, .trim, .mute, .rotate, .snapshot], hovered: 1, idle: "84 MB"))
        save("hero.png", hero())

        save("tool-crop.png", desk(CropToolView(document: doc(), close: {}, ratio: .square), size: CGSize(width: 440, height: 660)))
        save("tool-background.png", desk(BackgroundToolView(document: doc(), close: {}), size: CGSize(width: 470, height: 690)))
        var adjustments = ImageAdjustments()
        adjustments.warmth = 0.35
        adjustments.contrast = 1.12
        adjustments.saturation = 1.2
        save("tool-edit.png", desk(EditToolView(document: doc(), close: {}, adjustments: adjustments), size: CGSize(width: 470, height: 720)))
        let notes: [Annotation] = [
            Annotation(kind: .arrow(CGPoint(x: 0.78, y: 0.12), CGPoint(x: 0.52, y: 0.2)), color: RGBA(hex: 0xFF3B30), size: 0.007),
            Annotation(kind: .ellipse(CGRect(x: 0.08, y: 0.16, width: 0.5, height: 0.09)), color: RGBA(hex: 0xFF3B30), size: 0.006),
            Annotation(kind: .highlighter([CGPoint(x: 0.1, y: 0.42), CGPoint(x: 0.8, y: 0.42)]), color: RGBA(hex: 0xFFCC00), size: 0.007),
            Annotation(kind: .text("Check this", CGPoint(x: 0.6, y: 0.06)), color: RGBA(hex: 0xFF3B30), size: 0.007),
        ]
        save("tool-annotate.png", desk(AnnotateToolView(document: doc(), close: {}, annotations: notes), size: CGSize(width: 560, height: 680)))
        let boxes = [CGRect(x: 0.1, y: 0.3, width: 0.55, height: 0.04), CGRect(x: 0.205, y: 0.468, width: 0.36, height: 0.035)]
        save("tool-redact.png", desk(RedactToolView(document: doc(), close: {}, boxes: boxes), size: CGSize(width: 540, height: 680)))
        save("toast.png", toast())
        return ok
    }

    // MARK: - Pieces

    static func wheel(formats: [OutputFormat], hovered: Int?, idle: String) -> some View {
        wheelView(items: formats.map { WheelItem(action: .convert($0), title: $0.title, symbol: nil) }, hovered: hovered, idle: idle)
    }

    static func wheel(tools: [ToolKind], hovered: Int?, idle: String) -> some View {
        wheelView(items: tools.map { WheelItem(action: .tool($0), title: L10n.title(for: .tool($0)), symbol: $0.symbolName) },
                  hovered: hovered, idle: idle)
    }

    static func wheelView(items: [WheelItem], hovered: Int?, idle: String) -> some View {
        let model = WheelModel()
        model.items = items
        model.hovered = hovered
        model.idleText = idle
        model.diameter = 260
        model.isPresented = true
        return ZStack {
            wallpaper
            WheelView(model: model)
        }
        .frame(width: 340, height: 340)
    }

    static var wallpaper: some View {
        Canvas { ctx, size in
            ctx.withCGContext { cg in
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                GradientPreset.all[0].draw(in: cg, rect: CGRect(origin: .zero, size: size))
            }
        }
    }

    /// A plain, unbranded document icon (system icons can carry other apps' artwork).
    static func documentIcon(_ ext: String, size: CGFloat = 64) -> some View {
        let w = size * 0.78, h = size
        return ZStack(alignment: .topTrailing) {
            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, bottomTrailingRadius: 4,
                                   topTrailingRadius: size * 0.22, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            Path { p in
                let d = size * 0.22
                p.move(to: CGPoint(x: w - d, y: 0))
                p.addLine(to: CGPoint(x: w - d, y: d))
                p.addLine(to: CGPoint(x: w, y: d))
                p.closeSubpath()
            }
            .fill(Color(white: 0.85))
            VStack(spacing: size * 0.05) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().fill(Color(white: 0.82)).frame(height: size * 0.035)
                }
            }
            .padding(.horizontal, size * 0.14)
            .padding(.top, size * 0.3)
            .frame(width: w, height: h, alignment: .top)
            Text(ext.uppercased())
                .font(.system(size: size * 0.16, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, size * 0.06)
                .padding(.vertical, size * 0.02)
                .background(RoundedRectangle(cornerRadius: 2).fill(Theme.tangerineDeep))
                .frame(width: w, height: h, alignment: .bottom)
                .padding(.bottom, size * 0.12)
        }
        .frame(width: w, height: h)
    }

    static func desktopFile(_ name: String, ext: String, selected: Bool = false) -> some View {
        VStack(spacing: 3) {
            documentIcon(ext)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.blue : .clear))
                .shadow(color: .black.opacity(selected ? 0 : 0.5), radius: 1.5, y: 1)
        }
    }

    static func hero() -> some View {
        let model = WheelModel()
        model.items = [OutputFormat.docx, .jpg, .png, .txt].map { WheelItem(action: .convert($0), title: $0.title, symbol: nil) }
        model.hovered = 1
        model.idleText = "1.1 MB"
        model.diameter = 300
        model.isPresented = true
        return ZStack {
            wallpaper
            desktopFile("Page 001.pdf", ext: "pdf").position(x: 250, y: 300).opacity(0.55)
            WheelView(model: model).position(x: 480, y: 300)
            VStack(spacing: 2) {
                documentIcon("pdf", size: 56).opacity(0.9)
                Text("Page 001.pdf")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue))
            }
            .position(x: 596, y: 310)
            Text("⇧ Shift").font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.85)))
                .position(x: 480, y: 92)
        }
        .frame(width: 900, height: 560)
    }

    static func desk<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            wallpaper
            view
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        }
        .frame(width: size.width + 120, height: size.height + 120)
    }

    static func toast() -> some View {
        let running = ToastItem(title: L("Cropping image"), subtitle: L10n.progress(0, of: 1), progress: 0.45)
        let done = ToastItem(title: "Page 001 Cropped.jpg", subtitle: L("Saved next to the original"), progress: 1)
        done.state = .succeeded
        return ZStack {
            wallpaper
            VStack(spacing: 8) {
                ToastCard(item: running)
                ToastCard(item: done)
            }
            .frame(width: 300)
        }
        .frame(width: 380, height: 200)
    }

    /// A text page to show in the tool previews (original sample text).
    static func samplePage() -> CGImage {
        let w = 1275, h = 1650
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImageIOHelpers.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        ("Orchard Notes — Week 14" as NSString).draw(at: NSPoint(x: 110, y: h - 190), withAttributes: title)
        let lines = [
            "The kumquat trees on the south wall flowered early this",
            "year. Fruit set looks strong on the two older trees, while",
            "the young grafts still need shade in the afternoon.",
            "",
            "Watering: twice a week, deeper soaks instead of daily",
            "sprinkling. Mulch was topped up after the rain.",
            "",
            "Pests: a few aphids on new growth; washed off with water.",
            "No sign of scale insects this season.",
            "",
            "Harvest plan: pick when fully orange and slightly soft.",
            "Set aside a basket for marmalade and one for the market.",
            "",
            "Next week: prune crossing branches, check the drip line,",
            "and photograph the trees for the planting journal.",
        ]
        var y = h - 300
        for line in lines {
            (line as NSString).draw(at: NSPoint(x: 110, y: y), withAttributes: body)
            y -= 46
        }
        NSGraphicsContext.current = previous
        return ctx.makeImage()!
    }
}
