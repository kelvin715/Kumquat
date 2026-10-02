import Foundation

public struct ConversionOptions: Sendable {
    /// Quality for JPG/HEIC/AVIF when converting formats (0...1).
    public var imageQuality: Double = 0.9
    /// Quality used by the Compress tool (0...1).
    public var compressQuality: Double = 0.65
    /// Resolution PDF pages are rendered at when converting to images.
    public var pdfDPI: Double = 300
    /// Prefer lossless WebP even when cwebp is available.
    public var webpLossless: Bool = false
    /// Quality for lossy WebP via cwebp (0...100).
    public var webpQuality: Double = 85
    public var gifFrameRate: Double = 12
    public var gifMaxWidth: Int = 480
    public var gifMaxDuration: Double = 30
    /// Languages for text recognition (OCR) when making DOCX/TXT from images and scans.
    public var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]

    public init() {}
}
