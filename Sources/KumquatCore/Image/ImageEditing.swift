import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// An sRGB colour that can cross actor boundaries.
public struct RGBA: Sendable, Hashable, Codable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xff) / 255
        g = Double((hex >> 8) & 0xff) / 255
        b = Double(hex & 0xff) / 255
        a = alpha
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}

// MARK: - Saving

public enum ImageOutput {
    /// Saves an edited (upright) image next to `input` as "Name <tag>.ext", keeping the original
    /// format when it can be written.
    @discardableResult
    public static func save(_ image: CGImage, like input: URL, tag: String, forcePNG: Bool = false) throws -> URL {
        let source = FileClassifier.sourceFormat(of: input)
        let writable = Capabilities.detect(useExternalTools: false)
        var format: OutputFormat
        switch source {
        case .jpg, .png, .heic, .tiff, .bmp, .webp: format = source!
        case .avif: format = writable.canWriteAVIF ? .avif : .png
        case .none: format = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(input.pathExtension.lowercased()) ? .jpg : .png
        default: format = .png
        }
        if forcePNG { format = .png }
        if format == .heic && !writable.canWriteHEIC { format = .jpg }

        var props: [CFString: Any] = [:]
        if let src = try? ImageIOHelpers.source(input), format != .bmp {
            props = ImageIOHelpers.portableMetadata(ImageIOHelpers.properties(src), keepOrientation: false)
        }
        let ext = format == .jpg && ["jpeg", "jpg"].contains(input.pathExtension.lowercased())
            ? input.pathExtension : format.fileExtension
        let destination = OutputNaming.taggedURL(for: input, tag: tag, ext: ext)
        return try OutputNaming.write(to: destination) { out in
            switch format {
            case .webp:
                try ImageConverter.encodeWebPLossless(image, to: out)
            case .jpg, .bmp:
                props[kCGImageDestinationLossyCompressionQuality] = 0.92
                try ImageIOHelpers.write(ImageIOHelpers.flatten(image), to: out,
                                         type: ImageIOHelpers.utType(for: format), properties: props)
            case .heic, .avif:
                props[kCGImageDestinationLossyCompressionQuality] = 0.9
                try ImageIOHelpers.write(image, to: out, type: ImageIOHelpers.utType(for: format), properties: props)
            case .tiff:
                ImageIOHelpers.applyLZW(&props)
                try ImageIOHelpers.write(image, to: out, type: .tiff, properties: props)
            default:
                try ImageIOHelpers.write(image, to: out, type: ImageIOHelpers.utType(for: format), properties: props)
            }
        }
    }
}

// MARK: - Crop

public enum ImageCrop {
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    /// Largest rect with the given aspect ratio (width / height), centred in `size`.
    public static func centeredRect(aspect: Double, in size: CGSize) -> CGRect {
        var w = size.width, h = size.width / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

// MARK: - Background

public struct GradientPreset: Sendable, Hashable, Identifiable {
    public struct Blob: Sendable, Hashable {
        public var color: RGBA
        /// Centre in unit coordinates (y-down).
        public var x: Double, y: Double
        /// Radius as a fraction of the canvas diagonal.
        public var radius: Double
    }

    public let id: String
    public let colors: [RGBA]
    /// Direction of the base gradient in degrees (0 = left → right, 90 = top → bottom).
    public let angle: Double
    public let blobs: [Blob]

    public static let all: [GradientPreset] = [
        GradientPreset(id: "citrus", colors: [RGBA(hex: 0xFF5F3D), RGBA(hex: 0xFFB648)], angle: 300,
                       blobs: [Blob(color: RGBA(hex: 0xFF3E86), x: 0.1, y: 0.95, radius: 0.55),
                               Blob(color: RGBA(hex: 0x7C6CFF), x: 0.95, y: 0.95, radius: 0.5),
                               Blob(color: RGBA(hex: 0xFFD25A), x: 0.85, y: 0.05, radius: 0.45)]),
        GradientPreset(id: "cloud", colors: [RGBA(hex: 0xFFFFFF), RGBA(hex: 0xCFE0FF)], angle: 90,
                       blobs: [Blob(color: RGBA(hex: 0xE9D9FF), x: 0.9, y: 0.1, radius: 0.5)]),
        GradientPreset(id: "prism", colors: [RGBA(hex: 0xFF9AD5), RGBA(hex: 0xFFE27A), RGBA(hex: 0x8DF0B5), RGBA(hex: 0x7DB7FF)],
                       angle: 45, blobs: []),
        GradientPreset(id: "lilac", colors: [RGBA(hex: 0xF4EDFF), RGBA(hex: 0xFFFFFF)], angle: 90,
                       blobs: [Blob(color: RGBA(hex: 0xD8C3FF), x: 0.2, y: 0.9, radius: 0.6)]),
        GradientPreset(id: "rose", colors: [RGBA(hex: 0xFFC2E2), RGBA(hex: 0xE3B5FF)], angle: 30,
                       blobs: [Blob(color: RGBA(hex: 0xFFE3F1), x: 0.2, y: 0.15, radius: 0.5)]),
        GradientPreset(id: "aurora", colors: [RGBA(hex: 0x10222B), RGBA(hex: 0x24414F)], angle: 90,
                       blobs: [Blob(color: RGBA(hex: 0x00C2A0), x: 0.2, y: 0.3, radius: 0.55),
                               Blob(color: RGBA(hex: 0xFF5C6E), x: 0.85, y: 0.8, radius: 0.5)]),
        GradientPreset(id: "lagoon", colors: [RGBA(hex: 0x3F8CFF), RGBA(hex: 0x22E1F5)], angle: 315, blobs: []),
        GradientPreset(id: "glacier", colors: [RGBA(hex: 0x34CFD9), RGBA(hex: 0x5D85E8)], angle: 60,
                       blobs: [Blob(color: RGBA(hex: 0xBDF6FF), x: 0.15, y: 0.1, radius: 0.45)]),
        GradientPreset(id: "pearl", colors: [RGBA(hex: 0xFFFFFF), RGBA(hex: 0xECEBF5)], angle: 90,
                       blobs: [Blob(color: RGBA(hex: 0xE6DDFF), x: 0.85, y: 0.85, radius: 0.55)]),
    ]

    public static let solids: [RGBA] = [
        RGBA(hex: 0xFFFFFF), RGBA(hex: 0xF5C443), RGBA(hex: 0x9FD356), RGBA(hex: 0x2EA15A), RGBA(hex: 0x1C9C8B),
        RGBA(hex: 0x3DC3DA), RGBA(hex: 0x2F66F2), RGBA(hex: 0x1E2A45), RGBA(hex: 0x7A4CF5),
    ]

    public func draw(in ctx: CGContext, rect: CGRect) {
        let space = ImageIOHelpers.sRGB
        ctx.saveGState()
        ctx.clip(to: rect)
        if colors.count == 1 {
            ctx.setFillColor(colors[0].cgColor)
            ctx.fill(rect)
        } else if let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil) {
            // Angle is measured y-down; CG is y-up.
            let radians = angle * .pi / 180
            let dx = cos(radians), dy = -sin(radians)
            let half = (abs(dx) * rect.width + abs(dy) * rect.height) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                                   end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let diagonal = (rect.width * rect.width + rect.height * rect.height).squareRoot()
        for blob in blobs {
            let colors = [blob.color.cgColor, blob.color.cgColor.copy(alpha: 0) ?? blob.color.cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            let center = CGPoint(x: rect.minX + blob.x * rect.width, y: rect.maxY - blob.y * rect.height)
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: blob.radius * diagonal, options: [])
        }
        ctx.restoreGState()
    }
}

public enum BackgroundFill: Sendable, Hashable {
    case gradient(GradientPreset)
    case solid(RGBA)
    case image(URL)
}

public enum CanvasRatio: String, CaseIterable, Sendable {
    case auto = "Auto"
    case square = "1:1"
    case wide = "16:9"
    case portrait = "4:5"

    var value: Double? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .wide: return 16.0 / 9.0
        case .portrait: return 4.0 / 5.0
        }
    }
}

public struct BackgroundParams: Sendable, Hashable {
    public var fill: BackgroundFill
    /// Pixels of space around the image.
    public var padding: Double
    public var cornerRadius: Double
    /// Shadow blur radius in pixels.
    public var shadow: Double
    public var ratio: CanvasRatio

    public init(fill: BackgroundFill, padding: Double, cornerRadius: Double, shadow: Double, ratio: CanvasRatio) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.ratio = ratio
    }

    /// Defaults proportional to the picture, matching what looks right on a 2550 px page.
    public static func defaults(for size: CGSize) -> BackgroundParams {
        let longest = max(size.width, size.height), shortest = min(size.width, size.height)
        return BackgroundParams(fill: .gradient(GradientPreset.all[0]),
                                padding: (longest * 0.0625).rounded(),
                                cornerRadius: (shortest * 0.012).rounded(),
                                shadow: (longest * 0.01).rounded(),
                                ratio: .auto)
    }

    /// The same look at a different resolution (for previews).
    public func scaled(by factor: Double) -> BackgroundParams {
        var p = self
        p.padding *= factor
        p.cornerRadius *= factor
        p.shadow *= factor
        return p
    }
}

public enum BackgroundComposer {
    public static func canvasSize(for imageSize: CGSize, params: BackgroundParams) -> CGSize {
        var w = imageSize.width + 2 * params.padding
        var h = imageSize.height + 2 * params.padding
        if let r = params.ratio.value {
            if w / h < r { w = h * r } else { h = w / r }
        }
        return CGSize(width: w.rounded(), height: h.rounded())
    }

    public static func compose(_ image: CGImage, params: BackgroundParams, backgroundImage: CGImage? = nil) -> CGImage? {
        let size = canvasSize(for: CGSize(width: image.width, height: image.height), params: params)
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, w <= 20000, h <= 20000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high

        switch params.fill {
        case .gradient(let preset):
            preset.draw(in: ctx, rect: canvas)
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(canvas)
        case .image:
            if let bg = backgroundImage {
                // Aspect-fill.
                let scale = max(canvas.width / CGFloat(bg.width), canvas.height / CGFloat(bg.height))
                let dw = CGFloat(bg.width) * scale, dh = CGFloat(bg.height) * scale
                ctx.draw(bg, in: CGRect(x: (canvas.width - dw) / 2, y: (canvas.height - dh) / 2, width: dw, height: dh))
            } else {
                ctx.setFillColor(RGBA.white.cgColor)
                ctx.fill(canvas)
            }
        }

        let imageRect = CGRect(x: ((size.width - CGFloat(image.width)) / 2).rounded(),
                               y: ((size.height - CGFloat(image.height)) / 2).rounded(),
                               width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = min(params.cornerRadius, min(imageRect.width, imageRect.height) / 2)
        let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if params.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -params.shadow * 0.35), blur: params.shadow * 1.5,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

// MARK: - Redaction

public enum RedactionStyle: String, CaseIterable, Sendable {
    case blackout = "Black Box"
    case pixelate = "Pixelate"
    case blur = "Blur"
}

public enum Redactor {
    /// `regions` are normalized (0...1), y-down.
    public static func redact(_ image: CGImage, regions: [CGRect], style: RedactionStyle,
                              context: CIContext = CIContext()) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rects = regions.map { r in
            CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h).integral
        }
        let base = CIImage(cgImage: image)
        let strength = max(8, min(w, h) / 45)
        var output = base
        switch style {
        case .blackout:
            for rect in rects {
                let box = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
                output = box.composited(over: output)
            }
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")!
            filter.setValue(base.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(strength, forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            guard let pixelated = filter.outputImage else { return nil }
            for rect in rects { output = pixelated.cropped(to: rect).composited(over: output) }
        case .blur:
            let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: strength * 1.2)
            for rect in rects { output = blurred.cropped(to: rect).composited(over: output) }
        }
        return context.createCGImage(output.cropped(to: base.extent), from: base.extent,
                                     format: .RGBA8, colorSpace: ImageIOHelpers.sRGB)
    }
}

// MARK: - Adjustments

public struct ImageAdjustments: Sendable, Hashable {
    /// Stops, -2...2.
    public var exposure: Double = 0
    /// 0.5...1.5
    public var contrast: Double = 1
    /// 0...2
    public var saturation: Double = 1
    /// -1 (cooler) ... 1 (warmer)
    public var warmth: Double = 0
    /// 0...1, lower recovers highlights.
    public var highlights: Double = 1
    /// -1...1, higher lifts shadows.
    public var shadows: Double = 0
    /// -1...1
    public var vibrance: Double = 0
    /// 0...1
    public var sharpness: Double = 0
    /// 0...1
    public var vignette: Double = 0
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init() {}

    public var isIdentity: Bool { self == ImageAdjustments() }
}

public enum ImageAdjuster {
    public static func apply(_ adj: ImageAdjustments, to image: CGImage, context: CIContext = CIContext()) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if adj.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: adj.exposure])
        }
        if adj.contrast != 1 || adj.saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: adj.contrast,
                                                                   kCIInputSaturationKey: adj.saturation,
                                                                   kCIInputBrightnessKey: 0])
        }
        if adj.warmth != 0 {
            // Telling Core Image the scene was lit by a cooler light warms the picture, and vice versa.
            let neutral = 6500 - adj.warmth * 2500
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: neutral, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if adj.highlights != 1 || adj.shadows != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": adj.highlights,
                                                                           "inputShadowAmount": adj.shadows])
        }
        if adj.vibrance != 0 {
            ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": adj.vibrance])
        }
        if adj.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: adj.sharpness * 1.5,
                                                                      kCIInputRadiusKey: max(1.5, Double(min(extent.width, extent.height)) / 800)])
        }
        if adj.vignette > 0 {
            let radius = Double(max(extent.width, extent.height)) * 0.75
            ci = ci.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: radius,
                kCIInputIntensityKey: adj.vignette,
                "inputFalloff": 0.6,
            ])
        }
        ci = ci.cropped(to: extent)

        var orientation = CGImagePropertyOrientation.up
        switch ((adj.quarterTurns % 4) + 4) % 4 {
        case 1: orientation = .right
        case 2: orientation = .down
        case 3: orientation = .left
        default: break
        }
        ci = ci.oriented(orientation)
        if adj.flipHorizontal { ci = ci.oriented(.upMirrored) }
        if adj.flipVertical { ci = ci.oriented(.downMirrored) }
        let final = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return context.createCGImage(final, from: final.extent, format: .RGBA8, colorSpace: ImageIOHelpers.sRGB)
    }
}

// MARK: - Annotations

public struct Annotation: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case pen([CGPoint])
        case highlighter([CGPoint])
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(String, CGPoint)
    }

    public var id = UUID()
    /// Geometry in unit coordinates (0...1, y-down).
    public var kind: Kind
    public var color: RGBA
    /// Stroke width (or font size for text) as a fraction of the image's longest side.
    public var size: Double

    public init(kind: Kind, color: RGBA, size: Double) {
        self.kind = kind
        self.color = color
        self.size = size
    }
}

public enum AnnotationRenderer {
    public static func render(_ annotations: [Annotation], on image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Work y-down like the editor.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, in: ctx, size: CGSize(width: w, height: h))
        return ctx.makeImage()
    }

    /// Draws into a y-down context of the given size.
    public static func draw(_ annotations: [Annotation], in ctx: CGContext, size: CGSize) {
        let longest = max(size.width, size.height)
        func p(_ u: CGPoint) -> CGPoint { CGPoint(x: u.x * size.width, y: u.y * size.height) }
        func r(_ u: CGRect) -> CGRect {
            CGRect(x: u.minX * size.width, y: u.minY * size.height, width: u.width * size.width, height: u.height * size.height)
        }

        for a in annotations {
            let width = max(1, a.size * longest)
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineWidth(width)
            switch a.kind {
            case .pen(let points):
                ctx.addPath(smoothPath(points.map(p)))
                ctx.strokePath()
            case .highlighter(let points):
                ctx.setStrokeColor(a.color.cgColor.copy(alpha: 0.38) ?? a.color.cgColor)
                ctx.setLineWidth(width * 4)
                ctx.setLineCap(.square)
                ctx.setBlendMode(.multiply)
                ctx.addPath(smoothPath(points.map(p)))
                ctx.strokePath()
            case .arrow(let start, let end):
                let s = p(start), e = p(end)
                let angle = atan2(e.y - s.y, e.x - s.x)
                let head = width * 4.5
                let base = CGPoint(x: e.x - cos(angle) * head * 0.8, y: e.y - sin(angle) * head * 0.8)
                ctx.move(to: s)
                ctx.addLine(to: base)
                ctx.strokePath()
                ctx.move(to: e)
                ctx.addLine(to: CGPoint(x: e.x - cos(angle - 0.45) * head, y: e.y - sin(angle - 0.45) * head))
                ctx.addLine(to: CGPoint(x: e.x - cos(angle + 0.45) * head, y: e.y - sin(angle + 0.45) * head))
                ctx.closePath()
                ctx.fillPath()
            case .rectangle(let rect):
                ctx.stroke(r(rect).standardized)
            case .ellipse(let rect):
                ctx.strokeEllipse(in: r(rect).standardized)
            case .text(let string, let origin):
                let fontSize = max(8, a.size * longest * 6)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: a.color.nsColor,
                ]
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                (string as NSString).draw(at: p(origin), withAttributes: attributes)
                NSGraphicsContext.current = previous
            }
            ctx.restoreGState()
        }
    }

    /// A smooth curve through the points (midpoint quadratic interpolation).
    public static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
            return path
        }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
