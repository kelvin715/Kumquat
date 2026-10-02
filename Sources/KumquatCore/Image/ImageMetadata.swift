import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageMetadata {
    public struct Entry: Identifiable, Sendable, Hashable {
        public var id: String { section + "/" + label }
        public var section: String
        public var label: String
        public var value: String
    }

    public struct Summary: Sendable {
        public var entries: [Entry]
        public var latitude: Double?
        public var longitude: Double?
        public var hasCameraData: Bool
        public var hasLocation: Bool { latitude != nil && longitude != nil }
    }

    public enum StripMode: Sendable {
        case location
        case everything
    }

    public static func summary(of url: URL) throws -> Summary {
        let src = try ImageIOHelpers.source(url)
        let props = ImageIOHelpers.properties(src)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var entries: [Entry] = []

        func add(_ section: String, _ label: String, _ value: Any?) {
            guard let value else { return }
            let text: String
            switch value {
            case let s as String: text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            case let n as NSNumber: text = n.stringValue
            case let a as [Any]: text = a.map { "\($0)" }.joined(separator: ", ")
            default: text = "\(value)"
            }
            if !text.isEmpty { entries.append(Entry(section: section, label: label, value: text)) }
        }

        let size = ImageIOHelpers.pixelSize(props)
        add("Image", "Dimensions", "\(Int(size.width)) × \(Int(size.height)) px")
        add("Image", "File size", ByteCountFormatter.string(fromByteCount: FileClassifier.fileSize(of: url), countStyle: .file))
        if let type = CGImageSourceGetType(src) { add("Image", "Format", type as String) }
        if let dpi = props[kCGImagePropertyDPIWidth] as? NSNumber { add("Image", "Resolution", "\(dpi.intValue) dpi") }
        add("Image", "Color model", props[kCGImagePropertyColorModel])
        add("Image", "Color profile", props[kCGImagePropertyProfileName])
        add("Image", "Bit depth", props[kCGImagePropertyDepth])
        let orientation = ImageIOHelpers.orientation(props)
        if orientation != .up { add("Image", "Orientation", "\(orientation.rawValue)") }

        add("Camera", "Make", tiff[kCGImagePropertyTIFFMake])
        add("Camera", "Model", tiff[kCGImagePropertyTIFFModel])
        add("Camera", "Lens", exif[kCGImagePropertyExifLensModel])
        if let f = exif[kCGImagePropertyExifFNumber] as? NSNumber { add("Camera", "Aperture", "ƒ/\(f.doubleValue)") }
        if let t = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
            let v = t.doubleValue
            add("Camera", "Shutter", v < 1 && v > 0 ? "1/\(Int((1 / v).rounded())) s" : "\(v) s")
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { add("Camera", "ISO", iso) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? NSNumber { add("Camera", "Focal length", "\(focal.doubleValue) mm") }
        add("Camera", "Taken", exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        add("Camera", "Software", tiff[kCGImagePropertyTIFFSoftware])

        add("Author", "Artist", tiff[kCGImagePropertyTIFFArtist])
        add("Author", "Copyright", tiff[kCGImagePropertyTIFFCopyright] ?? iptc[kCGImagePropertyIPTCCopyrightNotice])
        add("Author", "Caption", iptc[kCGImagePropertyIPTCCaptionAbstract] ?? tiff[kCGImagePropertyTIFFImageDescription])
        add("Author", "Keywords", iptc[kCGImagePropertyIPTCKeywords])

        var latitude: Double?
        var longitude: Double?
        if let lat = gps[kCGImagePropertyGPSLatitude] as? NSNumber, let lon = gps[kCGImagePropertyGPSLongitude] as? NSNumber {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            latitude = lat.doubleValue * (latRef == "S" ? -1 : 1)
            longitude = lon.doubleValue * (lonRef == "W" ? -1 : 1)
            add("Location", "Coordinates", String(format: "%.5f, %.5f", latitude!, longitude!))
            if let alt = gps[kCGImagePropertyGPSAltitude] as? NSNumber { add("Location", "Altitude", "\(Int(alt.doubleValue)) m") }
        }

        let hasCamera = !exif.isEmpty || tiff[kCGImagePropertyTIFFMake] != nil
        return Summary(entries: entries, latitude: latitude, longitude: longitude, hasCameraData: hasCamera)
    }

    /// Writes a copy without location data, or without any metadata. Lossless for JPEG, PNG,
    /// TIFF and HEIC; other formats are re-encoded.
    public static func strip(_ input: URL, mode: StripMode) throws -> URL {
        let tag = mode == .location ? "No Location" : "No Metadata"
        let destination = OutputNaming.taggedURL(for: input, tag: tag)
        return try OutputNaming.write(to: destination) { out in
            let src = try ImageIOHelpers.source(input)
            guard let type = CGImageSourceGetType(src),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
            else { throw KumquatError.encodeFailed(destination.lastPathComponent) }

            var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if mode == .everything {
                // Replace all metadata with just the orientation, so the picture still displays upright.
                let metadata = CGImageMetadataCreateMutable()
                let orientation = ImageIOHelpers.orientation(ImageIOHelpers.properties(src))
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation,
                                                             NSNumber(value: orientation.rawValue))
                options[kCGImageDestinationMetadata] = metadata
                options[kCGImageDestinationMergeMetadata] = false
                options[kCGImageMetadataShouldExcludeXMP] = true
            }
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) {
                return
            }
            // Formats without lossless metadata editing: re-encode the pixels only.
            let image = try ImageIOHelpers.loadImage(from: src, name: input.lastPathComponent)
            var props: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationLossyCompressionQuality: 0.95]
            if mode == .location {
                props.merge(ImageIOHelpers.portableMetadata(ImageIOHelpers.properties(src), keepOrientation: false)) { a, _ in a }
                props[kCGImagePropertyGPSDictionary] = nil
            }
            try? FileManager.default.removeItem(at: out)
            try ImageIOHelpers.write(image, to: out, type: UTType(type as String) ?? .png, properties: props)
        }
    }
}
