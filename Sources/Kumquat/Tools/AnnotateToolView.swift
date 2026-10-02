import KumquatCore
import SwiftUI

enum AnnotationTool: String, CaseIterable {
    case pen, highlighter, arrow, rectangle, ellipse, text

    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }

    var help: String {
        switch self {
        case .pen: return L("Pen")
        case .highlighter: return L("Highlighter")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .text: return L("Text")
        }
    }
}

struct AnnotateToolView: View {
    @StateObject private var doc: ImageDocument
    let close: () -> Void

    @State private var annotations: [Annotation] = []
    @State private var draft: Annotation?
    @State private var tool: AnnotationTool = .arrow
    @State private var color = RGBA(hex: 0xFF3B30)
    @State private var size = 1
    @State private var text = ""

    static let colors: [RGBA] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x007AFF, 0xAF52DE, 0x111111, 0xFFFFFF].map { RGBA(hex: $0) }
    static let widths: [Double] = [0.004, 0.007, 0.012]

    init(document: ImageDocument, close: @escaping () -> Void, annotations: [Annotation] = []) {
        _doc = StateObject(wrappedValue: document)
        _annotations = State(initialValue: annotations)
        self.close = close
    }

    init(url: URL, close: @escaping () -> Void) {
        self.init(document: ImageDocument(url: url, previewSize: 1400), close: close)
    }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Annotate"), size: NSSize(width: 560, height: 680)) { close in
            AnnotateToolView(url: url, close: close)
        }
    }

    var body: some View {
        ToolChrome(title: L("Annotate"), close: close) {
            VStack(spacing: 10) {
                toolbar
                if tool == .text {
                    TextField(L("Type text, then click the picture to place it"), text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
                }
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } footer: {
            Button(L("Clear")) { annotations.removeAll() }.buttonStyle(SecondaryButtonStyle())
            Button(L("Undo")) { _ = annotations.popLast() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("z", modifiers: .command)
                .disabled(annotations.isEmpty)
            Spacer()
            Button(L("Save")) { save() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(annotations.isEmpty || doc.full == nil)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases, id: \.self) { t in
                Button { tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tool == t ? Color.white : Theme.ink)
                        .frame(width: 28, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tool == t ? AnyShapeStyle(Theme.segmentHover) : AnyShapeStyle(Theme.trackFill)))
                }
                .buttonStyle(.plain)
                .help(t.help)
            }
            Spacer(minLength: 8)
            ForEach(Self.colors, id: \.self) { c in
                Button { color = c } label: {
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                        .frame(width: 15, height: 15)
                        .padding(2)
                        .overlay(Circle().stroke(color == c ? Theme.tangerine : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            OrangeSegmented(options: [(0, "S"), (1, "M"), (2, "L")], selection: $size)
        }
    }

    @ViewBuilder private var canvas: some View {
        if let preview = doc.preview {
            GeometryReader { geo in
                let frame = FittedImage.fit(CGSize(width: preview.width, height: preview.height), in: geo.size)
                ZStack {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    Canvas { ctx, _ in
                        ctx.withCGContext { cg in
                            cg.translateBy(x: frame.minX, y: frame.minY)
                            cg.clip(to: CGRect(origin: .zero, size: frame.size))
                            AnnotationRenderer.draw(annotations + (draft.map { [$0] } ?? []), in: cg, size: frame.size)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(drawGesture(frame))
            }
            .coordinateSpace(name: "annotate")
        } else {
            LoadingView(error: doc.errorMessage)
        }
    }

    private func unit(_ p: CGPoint, _ imageFrame: CGRect) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        return CGPoint(x: min(max((p.x - imageFrame.minX) / imageFrame.width, 0), 1),
                       y: min(max((p.y - imageFrame.minY) / imageFrame.height, 0), 1))
    }

    private func drawGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("annotate"))
            .onChanged { g in
                let p = unit(g.location, frame)
                let start = unit(g.startLocation, frame)
                let width = Self.widths[size]
                switch tool {
                case .pen, .highlighter:
                    if case .pen(var points) = draft?.kind {
                        if let last = points.last, hypot(last.x - p.x, last.y - p.y) > 0.002 { points.append(p) }
                        draft?.kind = .pen(points)
                    } else if case .highlighter(var points) = draft?.kind {
                        if let last = points.last, hypot(last.x - p.x, last.y - p.y) > 0.002 { points.append(p) }
                        draft?.kind = .highlighter(points)
                    } else {
                        draft = Annotation(kind: tool == .pen ? .pen([start, p]) : .highlighter([start, p]), color: color, size: width)
                    }
                case .arrow:
                    draft = Annotation(kind: .arrow(start, p), color: color, size: width)
                case .rectangle:
                    draft = Annotation(kind: .rectangle(CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y)),
                                       color: color, size: width)
                case .ellipse:
                    draft = Annotation(kind: .ellipse(CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y)),
                                       color: color, size: width)
                case .text:
                    break
                }
            }
            .onEnded { g in
                if tool == .text {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        annotations.append(Annotation(kind: .text(trimmed, unit(g.location, frame)), color: color, size: Self.widths[size]))
                    }
                } else if let draft {
                    annotations.append(draft)
                }
                draft = nil
            }
    }

    private func save() {
        guard let full = doc.full else { return }
        let url = doc.url
        let annotations = annotations
        close()
        ToolWindowManager.shared.save(title: L("Saving annotations"), doneTitle: L("Annotations saved")) {
            guard let image = AnnotationRenderer.render(annotations, on: full) else { throw KumquatError.encodeFailed("annotation") }
            return try ImageOutput.save(image, like: url, tag: "Annotated")
        }
    }
}
