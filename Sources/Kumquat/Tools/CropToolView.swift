import KumquatCore
import SwiftUI

enum CropRatio: String, CaseIterable {
    case free, square, wide, tall, classic, portrait

    var label: String {
        switch self {
        case .free: return L("Free")
        case .square: return "1:1"
        case .wide: return "16:9"
        case .tall: return "9:16"
        case .classic: return "4:3"
        case .portrait: return "3:4"
        }
    }

    var value: Double? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .tall: return 9.0 / 16.0
        case .classic: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }
}

enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    /// Position in unit coordinates of the crop rect.
    var unit: CGPoint? {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .move: return nil
        }
    }
}

/// Crop rectangle maths, in image pixels (y-down).
enum CropMath {
    static let minimumSize: CGFloat = 16

    static func adjust(_ start: CGRect, handle: CropHandle, delta: CGSize, ratio: Double?, bounds: CGSize) -> CGRect {
        if handle == .move {
            var r = start.offsetBy(dx: delta.width, dy: delta.height)
            r.origin.x = min(max(0, r.origin.x), bounds.width - r.width)
            r.origin.y = min(max(0, r.origin.y), bounds.height - r.height)
            return r
        }
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .left: minX += delta.width
        case .right: maxX += delta.width
        case .top: minY += delta.height
        case .bottom: maxY += delta.height
        case .topLeft: minX += delta.width; minY += delta.height
        case .topRight: maxX += delta.width; minY += delta.height
        case .bottomLeft: minX += delta.width; maxY += delta.height
        case .bottomRight: maxX += delta.width; maxY += delta.height
        case .move: break
        }
        minX = min(max(0, minX), start.maxX - minimumSize)
        maxX = max(min(bounds.width, maxX), start.minX + minimumSize)
        minY = min(max(0, minY), start.maxY - minimumSize)
        maxY = max(min(bounds.height, maxY), start.minY + minimumSize)
        let free = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio else { return free }

        var w = free.width, h = free.height
        switch handle {
        case .left, .right: h = w / ratio
        case .top, .bottom: w = h * ratio
        default: if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        // The space available from the fixed side (or centre line) to the image edge.
        let maxW: CGFloat, maxH: CGFloat
        switch handle {
        case .bottomRight: (maxW, maxH) = (bounds.width - start.minX, bounds.height - start.minY)
        case .topLeft: (maxW, maxH) = (start.maxX, start.maxY)
        case .topRight: (maxW, maxH) = (bounds.width - start.minX, start.maxY)
        case .bottomLeft: (maxW, maxH) = (start.maxX, bounds.height - start.minY)
        case .right: (maxW, maxH) = (bounds.width - start.minX, 2 * min(start.midY, bounds.height - start.midY))
        case .left: (maxW, maxH) = (start.maxX, 2 * min(start.midY, bounds.height - start.midY))
        case .bottom: (maxW, maxH) = (2 * min(start.midX, bounds.width - start.midX), bounds.height - start.minY)
        case .top: (maxW, maxH) = (2 * min(start.midX, bounds.width - start.midX), start.maxY)
        case .move: (maxW, maxH) = (bounds.width, bounds.height)
        }
        w = max(min(w, maxW, maxH * ratio), minimumSize)
        h = w / ratio

        let x: CGFloat, y: CGFloat
        switch handle {
        case .topLeft: (x, y) = (start.maxX - w, start.maxY - h)
        case .topRight: (x, y) = (start.minX, start.maxY - h)
        case .bottomLeft: (x, y) = (start.maxX - w, start.minY)
        case .bottomRight: (x, y) = (start.minX, start.minY)
        case .left: (x, y) = (start.maxX - w, start.midY - h / 2)
        case .right: (x, y) = (start.minX, start.midY - h / 2)
        case .top: (x, y) = (start.midX - w / 2, start.maxY - h)
        case .bottom: (x, y) = (start.midX - w / 2, start.minY)
        case .move: (x, y) = (start.minX, start.minY)
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Largest rect of `ratio` around `center` that fits the image.
    static func largest(ratio: Double, around center: CGPoint, bounds: CGSize) -> CGRect {
        var w = bounds.width, h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        let x = min(max(0, center.x - w / 2), bounds.width - w)
        let y = min(max(0, center.y - h / 2), bounds.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Resizes around the centre to a typed size, keeping the ratio if one is set.
    static func resized(_ rect: CGRect, width: CGFloat?, height: CGFloat?, ratio: Double?, bounds: CGSize) -> CGRect {
        var w = width ?? rect.width, h = height ?? rect.height
        if let ratio {
            if width != nil { h = w / ratio } else { w = h * ratio }
        }
        let scale = min(1, bounds.width / max(w, 1), bounds.height / max(h, 1))
        w = max(minimumSize, w * scale)
        h = max(minimumSize, h * scale)
        let x = min(max(0, rect.midX - w / 2), bounds.width - w)
        let y = min(max(0, rect.midY - h / 2), bounds.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

struct CropToolView: View {
    @StateObject private var doc: ImageDocument
    let close: () -> Void

    @State private var rect: CGRect
    @State private var ratio: CropRatio = .free
    @State private var dragStart: CGRect?
    @State private var activeHandle: CropHandle?

    init(document: ImageDocument, close: @escaping () -> Void, ratio: CropRatio = .free) {
        _doc = StateObject(wrappedValue: document)
        let size = document.pixelSize
        let full = CGRect(origin: .zero, size: size)
        _ratio = State(initialValue: ratio)
        _rect = State(initialValue: ratio.value.map {
            CropMath.largest(ratio: $0, around: CGPoint(x: full.midX, y: full.midY * 0.8), bounds: size)
        } ?? full)
        self.close = close
    }

    init(url: URL, close: @escaping () -> Void) {
        self.init(document: ImageDocument(url: url), close: close)
    }

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Crop Image"), size: NSSize(width: 440, height: 660)) { close in
            CropToolView(url: url, close: close)
        }
    }

    private var bounds: CGSize { doc.pixelSize }

    var body: some View {
        ToolChrome(title: L("Crop Image"), close: close) {
            VStack(spacing: 14) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text(L("Aspect ratio")).font(.system(size: 11)).foregroundStyle(Theme.ink)
                    Spacer()
                    OrangeSegmented(options: CropRatio.allCases.map { ($0, $0.label) }, selection: $ratio)
                }
                HStack(spacing: 10) {
                    PixelField(label: "W", value: Binding(
                        get: { Int(rect.width.rounded()) },
                        set: { rect = CropMath.resized(rect, width: CGFloat($0), height: nil, ratio: ratio.value, bounds: bounds) }))
                    PixelField(label: "H", value: Binding(
                        get: { Int(rect.height.rounded()) },
                        set: { rect = CropMath.resized(rect, width: nil, height: CGFloat($0), ratio: ratio.value, bounds: bounds) }))
                    Text("px").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                    Spacer()
                }
            }
        } footer: {
            Button(L("Reset")) { reset() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L("Apply")) { apply() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(doc.preview == nil)
        }
        .onChange(of: doc.pixelSize) { reset() }
        .onChange(of: ratio) {
            guard let value = ratio.value, bounds.width > 0 else { return }
            rect = CropMath.largest(ratio: value, around: CGPoint(x: rect.midX, y: rect.midY), bounds: bounds)
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
                    overlay(frame)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(frame))
            }
            .coordinateSpace(name: "canvas")
        } else {
            LoadingView(error: doc.errorMessage)
        }
    }

    private func scale(_ frame: CGRect) -> CGFloat { bounds.width > 0 ? frame.width / bounds.width : 1 }

    private func displayRect(_ frame: CGRect) -> CGRect {
        let s = scale(frame)
        return CGRect(x: frame.minX + rect.minX * s, y: frame.minY + rect.minY * s,
                      width: rect.width * s, height: rect.height * s)
    }

    private func overlay(_ imageFrame: CGRect) -> some View {
        let r = displayRect(imageFrame)
        return ZStack {
            Path { p in
                p.addRect(imageFrame)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle()
                .stroke(Theme.tangerine, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            ForEach(CropHandle.allCases.filter { $0 != .move }, id: \.self) { handle in
                handleView(handle, in: r)
            }
        }
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: CropHandle, in r: CGRect) -> some View {
        let unit = handle.unit!
        let isCorner = unit.x != 0.5 && unit.y != 0.5
        let size: CGSize = isCorner ? CGSize(width: 9, height: 9)
            : (unit.x == 0.5 ? CGSize(width: 16, height: 4) : CGSize(width: 4, height: 16))
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.tangerine)
            .frame(width: size.width, height: size.height)
            .position(x: r.minX + unit.x * r.width, y: r.minY + unit.y * r.height)
    }

    private func dragGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if dragStart == nil {
                    dragStart = rect
                    activeHandle = handle(at: g.startLocation, frame: frame)
                }
                let s = scale(frame)
                guard let start = dragStart, let handle = activeHandle, s > 0 else { return }
                let delta = CGSize(width: g.translation.width / s, height: g.translation.height / s)
                rect = CropMath.adjust(start, handle: handle, delta: delta, ratio: ratio.value, bounds: bounds)
            }
            .onEnded { _ in
                dragStart = nil
                activeHandle = nil
            }
    }

    private func handle(at point: CGPoint, frame: CGRect) -> CropHandle? {
        let r = displayRect(frame)
        let grab: CGFloat = 14
        for handle in CropHandle.allCases {
            guard let unit = handle.unit else { continue }
            let p = CGPoint(x: r.minX + unit.x * r.width, y: r.minY + unit.y * r.height)
            if abs(point.x - p.x) <= grab && abs(point.y - p.y) <= grab { return handle }
        }
        // Edges anywhere along their length.
        if abs(point.x - r.minX) <= 8 && point.y > r.minY && point.y < r.maxY { return .left }
        if abs(point.x - r.maxX) <= 8 && point.y > r.minY && point.y < r.maxY { return .right }
        if abs(point.y - r.minY) <= 8 && point.x > r.minX && point.x < r.maxX { return .top }
        if abs(point.y - r.maxY) <= 8 && point.x > r.minX && point.x < r.maxX { return .bottom }
        return r.contains(point) ? .move : nil
    }

    private func reset() {
        ratio = .free
        rect = CGRect(origin: .zero, size: bounds)
    }

    private func apply() {
        guard let full = doc.full else { return }
        let url = doc.url
        let crop = rect.integral
        close()
        ToolWindowManager.shared.save(title: L("Cropping image"), doneTitle: L("Cropped")) {
            guard let cropped = ImageCrop.crop(full, to: crop) else { throw KumquatError.encodeFailed("crop") }
            return try ImageOutput.save(cropped, like: url, tag: "Cropped")
        }
    }
}
