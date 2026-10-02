import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOHelpers {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else { throw KumquatError.decodeFailed(url.lastPathComponent) }
        return src
    }

    public static func properties(_ src: CGImageSource, index: Int = 0) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]) ?? [:]
    }

    public static func orientation(_ props: [CFString: Any]) -> CGImagePropertyOrientation {
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
    }

    public static func pixelSize(_ props: [CFString: Any]) -> CGSize {
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: w, height: h)
    }

    /// Loads the first frame, rotated upright according to its EXIF orientation.
    /// Falls back to NSImage for formats ImageIO can't decode (e.g. SVG on newer systems).
    public static func loadImage(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if let src = try? source(url) {
            return try loadImage(from: src, maxPixelSize: maxPixelSize, name: url.lastPathComponent)
        }
        if let ns = NSImage(contentsOf: url), let cg = rasterize(ns, maxPixelSize: maxPixelSize) {
            return cg
        }
        throw KumquatError.decodeFailed(url.lastPathComponent)
    }

    public static func loadImage(from src: CGImageSource, maxPixelSize: Int? = nil, name: String = "image") throws -> CGImage {
        let props = properties(src)
        let size = pixelSize(props)
        let longest = Int(max(size.width, size.height))
        let target = maxPixelSize.map { min($0, longest > 0 ? longest : $0) } ?? longest
        let orientation = orientation(props)

        if orientation == .up && (maxPixelSize == nil || target >= longest),
           let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return image
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if target > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = target }
        if let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
            return image
        }
        throw KumquatError.decodeFailed(name)
    }

    static func rasterize(_ image: NSImage, maxPixelSize: Int?) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            rect.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        if rect.width <= 0 || rect.height <= 0 { return nil }
        if let maxPixelSize, max(rect.width, rect.height) > CGFloat(maxPixelSize) {
            let s = CGFloat(maxPixelSize) / max(rect.width, rect.height)
            rect.size = CGSize(width: rect.width * s, height: rect.height * s)
        }
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// True when any pixel is not fully opaque (an alpha channel alone doesn't mean transparency).
    public static func hasTransparency(_ image: CGImage) -> Bool {
        guard hasAlpha(image) else { return false }
        guard let buffer = RGBABuffer(image: image) else { return true }
        let pixels = buffer.pixels
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return true }
            i += 4
        }
        return false
    }

    /// Draws the image onto an opaque background (for JPG and BMP).
    public static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Redraws an image into a plain 8-bit sRGB RGBA bitmap.
    public static func normalized(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    public static func utType(for format: OutputFormat) -> UTType {
        switch format {
        case .jpg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .avif: return UTType("public.avif") ?? .image
        case .bmp: return .bmp
        case .gif: return .gif
        case .pdf: return .pdf
        default: return .data
        }
    }

    /// Writes a single image with ImageIO.
    public static func write(_ image: CGImage, to url: URL, type: UTType,
                             properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw KumquatError.encodeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(url.lastPathComponent) }
    }

    public static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw KumquatError.encodeFailed(type.preferredFilenameExtension ?? "image")
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw KumquatError.encodeFailed(type.preferredFilenameExtension ?? "image")
        }
        return data as Data
    }

    /// Turns on LZW compression for TIFF output (keeps any other TIFF tags).
    public static func applyLZW(_ props: inout [CFString: Any]) {
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5
        props[kCGImagePropertyTIFFDictionary] = tiff
    }

    /// Metadata dictionaries worth carrying across a conversion (camera info, GPS, captions, DPI).
    public static func portableMetadata(_ props: [CFString: Any], keepOrientation: Bool) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = props[key] { out[key] = value }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = keepOrientation ? props[kCGImagePropertyOrientation] ?? 1 : 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = keepOrientation ? (props[kCGImagePropertyOrientation] ?? 1) : 1
        return out
    }
}

/// Unpremultiplied 8-bit RGBA pixels, top row first.
public struct RGBABuffer {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init?(image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: ImageIOHelpers.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        // Undo premultiplication so encoders see the real colour of translucent pixels.
        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                pixels[i] = UInt8(min(255, (Int(pixels[i]) * 255 + a / 2) / a))
                pixels[i + 1] = UInt8(min(255, (Int(pixels[i + 1]) * 255 + a / 2) / a))
                pixels[i + 2] = UInt8(min(255, (Int(pixels[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var hasTransparency: Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return true }
            i += 4
        }
        return false
    }

    public func makeImage() -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: ImageIOHelpers.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
