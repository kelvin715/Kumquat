import KumquatCore
import SwiftUI

struct WatermarkToolView: View {
    let url: URL
    let close: () -> Void

    @State private var text = L("CONFIDENTIAL")
    @State private var fontSize = 54.0
    @State private var opacity = 0.18
    @State private var angle = 35.0
    @State private var color = RGBA(hex: 0xE5450D)
    @State private var tiled = false
    @State private var page: CGImage?
    @State private var pageSize: CGSize = .zero
    @State private var errorMessage: String?

    static let colors: [RGBA] = [0xE5450D, 0xD7263D, 0x1F2A44, 0x6B7280, 0x2F66F2].map { RGBA(hex: $0) }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Watermark"), size: NSSize(width: 460, height: 680)) { close in
            WatermarkToolView(url: url, close: close)
        }
    }

    private var mark: PDFTools.Watermark {
        PDFTools.Watermark(text: text, fontSize: fontSize, opacity: opacity, angle: angle, color: color.cgColor, tiled: tiled)
    }

    var body: some View {
        ToolChrome(title: L("Watermark"), close: close) {
            VStack(spacing: 12) {
                Group {
                    if let preview = composite() {
                        FittedImage(image: preview).shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    } else {
                        LoadingView(error: errorMessage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    FieldLabel(text: L("Text"))
                    TextField("", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
                }
                OrangeSlider(label: L("Size"), value: $fontSize, range: 12...200, unit: "pt")
                OrangeSlider(label: L("Opacity"), value: $opacity, range: 0.05...0.8, unit: "%",
                             format: { String(Int(($0 * 100).rounded())) })
                OrangeSlider(label: L("Angle"), value: $angle, range: -90...90, unit: "°")
                HStack {
                    FieldLabel(text: L("Colour"))
                    ForEach(Self.colors, id: \.self) { c in
                        Swatch(selected: color == c, action: { color = c }) { Color(nsColor: c.nsColor) }
                    }
                    Spacer()
                    OrangeSegmented(options: [(false, L("Centre")), (true, L("Tiled"))], selection: $tiled)
                }
            }
        } footer: {
            Button(L("Reset")) {
                fontSize = 54; opacity = 0.18; angle = 35; tiled = false; color = Self.colors[0]
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L("Add Watermark")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || page == nil)
        }
        .task { loadFirstPage() }
    }

    private func loadFirstPage() {
        do {
            let doc = try PDFRenderer.document(at: url)
            guard let first = doc.page(at: 1) else { return }
            let box = first.getBoxRect(.cropBox)
            let rotation = ((Int(first.rotationAngle) % 360) + 360) % 360
            pageSize = rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
            page = PDFRenderer.render(first, dpi: 110)
        } catch {
            errorMessage = ConversionEngine.message(for: error)
        }
    }

    private func composite() -> CGImage? {
        guard let page, pageSize.width > 0,
              let ctx = CGContext(data: nil, width: page.width, height: page.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(page, in: CGRect(x: 0, y: 0, width: page.width, height: page.height))
        ctx.scaleBy(x: CGFloat(page.width) / pageSize.width, y: CGFloat(page.height) / pageSize.height)
        PDFTools.drawWatermark(mark, in: ctx, size: pageSize)
        return ctx.makeImage()
    }

    private func save() {
        let url = url
        let mark = mark
        close()
        ToolWindowManager.shared.save(title: L("Adding watermark"), doneTitle: L("Watermark added")) {
            try PDFTools.watermark(url, with: mark)
        }
    }
}
