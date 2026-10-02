import CoreImage
import KumquatCore
import SwiftUI

struct RedactToolView: View {
    @StateObject private var doc: ImageDocument
    let close: () -> Void

    @State private var boxes: [CGRect] = []
    @State private var draft: CGRect?
    @State private var style: RedactionStyle = .blackout
    @State private var rendered: CGImage?
    @State private var detecting = false
    @State private var status = ""
    private let context: CIContext = SharedCoreImage.context

    init(document: ImageDocument, close: @escaping () -> Void, boxes: [CGRect] = []) {
        _doc = StateObject(wrappedValue: document)
        _boxes = State(initialValue: boxes)
        if let preview = document.preview, !boxes.isEmpty {
            _rendered = State(initialValue: Redactor.redact(preview, regions: boxes, style: .blackout))
        }
        self.close = close
    }

    init(url: URL, close: @escaping () -> Void) {
        self.init(document: ImageDocument(url: url, previewSize: 1400), close: close)
    }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Redact"), size: NSSize(width: 540, height: 680)) { close in
            RedactToolView(url: url, close: close)
        }
    }

    var body: some View {
        let languages = AppSettings.shared.conversionOptions.recognitionLanguages
        return ToolChrome(title: L("Redact"), close: close) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    OrangeSegmented(options: RedactionStyle.allCases.map { ($0, L($0.rawValue)) }, selection: $style)
                    Spacer()
                    detectButton(L("Find Text"), symbol: "text.viewfinder") { try TextRecognizer.textRegions(in: $0, languages: languages) }
                    detectButton(L("Find Faces"), symbol: "face.dashed") { try TextRecognizer.faceRegions(in: $0) }
                }
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(status.isEmpty ? L("Drag over anything you want to hide.") : status)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Button(L("Clear")) { boxes.removeAll(); status = "" }.buttonStyle(SecondaryButtonStyle())
            Button(L("Undo")) { _ = boxes.popLast() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("z", modifiers: .command)
                .disabled(boxes.isEmpty)
            Spacer()
            Button(L("Save")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(boxes.isEmpty || doc.full == nil)
        }
        .onChange(of: doc.preview != nil) { render() }
        .onChange(of: boxes) { render() }
        .onChange(of: style) { render() }
    }

    private func detectButton(_ title: String, symbol: String, detect: @escaping @Sendable (CGImage) throws -> [CGRect]) -> some View {
        Button {
            guard let preview = doc.preview else { return }
            detecting = true
            Task.detached(priority: .userInitiated) {
                let found = (try? detect(preview)) ?? []
                await MainActor.run {
                    detecting = false
                    let padded = found.map { $0.insetBy(dx: -$0.height * 0.12, dy: -$0.height * 0.15) }
                        .map { $0.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
                    let new = padded.filter { r in !boxes.contains { $0.intersects(r) && $0.intersection(r).width * $0.intersection(r).height > r.width * r.height * 0.6 } }
                    boxes += new
                    status = new.isEmpty ? L("Nothing found.") : (L10n.usesChinese ? "找到 \(new.count) 处" : "Found \(new.count).")
                }
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.trackFill))
        }
        .buttonStyle(.plain)
        .disabled(detecting || doc.preview == nil)
    }

    @ViewBuilder private var canvas: some View {
        if let image = rendered ?? doc.preview {
            GeometryReader { geo in
                let imageFrame = FittedImage.fit(CGSize(width: image.width, height: image.height), in: geo.size)
                canvasContent(image, imageFrame)
            }
            .coordinateSpace(name: "redact")
        } else {
            LoadingView(error: doc.errorMessage)
        }
    }

    private func canvasContent(_ image: CGImage, _ imageFrame: CGRect) -> some View {
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                ForEach(Array(boxes.enumerated()), id: \.offset) { index, box in
                    let r = display(box, imageFrame)
                    Rectangle()
                        .stroke(Theme.tangerine, lineWidth: 1)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    Button { boxes.remove(at: index) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white, Theme.tangerine)
                    }
                    .buttonStyle(.plain)
                    .position(x: r.maxX, y: r.minY)
                }
                if let draft {
                    let r = display(draft.standardized, imageFrame)
                    Rectangle()
                        .stroke(Theme.tangerine, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(Rectangle().fill(Color.black.opacity(0.25)))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("redact"))
                    .onChanged { g in
                        let a = unit(g.startLocation, imageFrame), b = unit(g.location, imageFrame)
                        draft = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                    }
                    .onEnded { _ in
                        if let r = draft?.standardized, r.width > 0.003, r.height > 0.003 { boxes.append(r) }
                        draft = nil
                    }
            )
    }

    private func unit(_ p: CGPoint, _ imageFrame: CGRect) -> CGPoint {
        guard imageFrame.width > 0 else { return .zero }
        return CGPoint(x: min(max((p.x - imageFrame.minX) / imageFrame.width, 0), 1),
                       y: min(max((p.y - imageFrame.minY) / imageFrame.height, 0), 1))
    }

    private func display(_ r: CGRect, _ imageFrame: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + r.minX * imageFrame.width, y: imageFrame.minY + r.minY * imageFrame.height,
               width: r.width * imageFrame.width, height: r.height * imageFrame.height)
    }

    private func render() {
        guard let preview = doc.preview else { return }
        rendered = boxes.isEmpty ? nil : Redactor.redact(preview, regions: boxes, style: style, context: context)
    }

    private func save() {
        guard let full = doc.full else { return }
        let url = doc.url
        let boxes = boxes
        let style = style
        close()
        ToolWindowManager.shared.save(title: L("Redacting"), doneTitle: L("Redacted copy saved")) {
            guard let image = Redactor.redact(full, regions: boxes, style: style) else { throw KumquatError.encodeFailed("redaction") }
            return try ImageOutput.save(image, like: url, tag: "Redacted")
        }
    }
}
