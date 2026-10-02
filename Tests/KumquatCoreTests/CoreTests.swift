import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import KumquatCore

final class WheelGeometryTests: XCTestCase {
    func testSegmentZeroIsAtTwelveOClockAndGoesClockwise() {
        let g = WheelGeometry(count: 4, radius: 100, center: CGPoint(x: 100, y: 100))
        XCTAssertEqual(g.hitTest(CGPoint(x: 100, y: 30)), .segment(0))   // top
        XCTAssertEqual(g.hitTest(CGPoint(x: 170, y: 100)), .segment(1))  // right
        XCTAssertEqual(g.hitTest(CGPoint(x: 100, y: 170)), .segment(2))  // bottom
        XCTAssertEqual(g.hitTest(CGPoint(x: 30, y: 100)), .segment(3))   // left
    }

    func testCentreAndOutside() {
        let g = WheelGeometry(count: 7, radius: 130, center: CGPoint(x: 150, y: 150))
        XCTAssertEqual(g.hitTest(CGPoint(x: 150, y: 150)), .center)
        XCTAssertEqual(g.hitTest(CGPoint(x: 150 + 300, y: 150)), .outside)
    }

    func testLabelCentresHitTheirOwnSegment() {
        for count in 1...10 {
            let g = WheelGeometry(count: count, radius: 130, center: CGPoint(x: 130, y: 130))
            for i in 0..<count {
                XCTAssertEqual(g.hitTest(g.labelCenter(of: i)), .segment(i), "count \(count), segment \(i)")
            }
        }
    }

    func testSegmentPathsAreNonEmptyAndInsideTheWheel() {
        for count in 1...10 {
            let g = WheelGeometry(count: count, radius: 130, center: CGPoint(x: 130, y: 130))
            for i in 0..<count {
                let box = g.segmentPath(index: i).boundingBoxOfPath
                XCTAssertFalse(box.isEmpty, "count \(count), segment \(i)")
                XCTAssertLessThanOrEqual(box.maxX, 260.5)
                XCTAssertGreaterThanOrEqual(box.minX, -0.5)
            }
        }
    }
}

final class CatalogAndNamingTests: XCTestCase {
    let catalog = ActionCatalog(capabilities: Capabilities(canWriteHEIC: true, canWriteAVIF: true, ffmpegURL: nil, cwebpURL: nil))

    func testPDFFormatsMatchTheReferenceOrder() {
        XCTAssertEqual(catalog.formats(for: URL(fileURLWithPath: "/x/Page 001.pdf")), [.docx, .jpg, .png, .txt])
    }

    func testJPGFormatsMatchTheReferenceOrder() {
        XCTAssertEqual(catalog.formats(for: URL(fileURLWithPath: "/x/a.jpeg")), [.png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx])
    }

    func testImageToolsMatchTheReferenceOrder() {
        let tools = catalog.toolActions(for: [URL(fileURLWithPath: "/x/a.jpg")])
        XCTAssertEqual(tools, [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .redact].map { WheelAction.tool($0) })
    }

    func testFFmpegOnlyFormatsAreHiddenWithoutFFmpeg() {
        let formats = catalog.formats(for: URL(fileURLWithPath: "/x/clip.mov"))
        XCTAssertFalse(formats.contains(.mp3))
        XCTAssertFalse(formats.contains(.webm))
        XCTAssertTrue(formats.contains(.mp4))
    }

    func testMixedSelectionsOfferOnlyCommonFormats() {
        let urls = [URL(fileURLWithPath: "/x/a.png"), URL(fileURLWithPath: "/x/b.jpg")]
        let formats = catalog.formatActions(for: urls)
        XCTAssertFalse(formats.contains(.convert(.png)))
        XCTAssertFalse(formats.contains(.convert(.jpg)))
        XCTAssertTrue(formats.contains(.convert(.webp)))
        XCTAssertTrue(catalog.formatActions(for: [URL(fileURLWithPath: "/x/a.png"), URL(fileURLWithPath: "/x/b.mp3")]).isEmpty)
    }

    func testToolsWheelFallsBackToFormatsForDocuments() {
        let urls = [URL(fileURLWithPath: "/x/notes.md")]
        XCTAssertEqual(catalog.actions(for: urls, mode: .tools), catalog.actions(for: urls, mode: .formats))
    }

    func testOutputNamesAreFinderStyleAndUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("Page 001.pdf")
        XCTAssertEqual(OutputNaming.convertedURL(for: input, ext: "jpg").lastPathComponent, "Page 001.jpg")
        XCTAssertEqual(OutputNaming.taggedURL(for: input, tag: "Cropped", ext: "jpg").lastPathComponent, "Page 001 Cropped.jpg")
        let first = try OutputNaming.write(to: dir.appendingPathComponent("Page 001.jpg")) { try Data([1]).write(to: $0) }
        let second = try OutputNaming.write(to: dir.appendingPathComponent("Page 001.jpg")) { try Data([2]).write(to: $0) }
        XCTAssertEqual(first.lastPathComponent, "Page 001.jpg")
        XCTAssertEqual(second.lastPathComponent, "Page 001 2.jpg")
        // No temporary files are left next to the result.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["Page 001 2.jpg", "Page 001.jpg"])
    }
}

final class DocumentTests: XCTestCase {
    func testDocxOpensInTextKitWithTextAndHeadings() throws {
        var doc = DocxDocument(title: "Test")
        doc.append(DocxParagraph("Big Title", style: .heading1))
        doc.append(DocxParagraph(runs: [DocxRun("Hello "), DocxRun("bold", bold: true), DocxRun(" & <escaped> 中文")]))
        doc.appendPageBreak()
        doc.append(DocxParagraph("Second page"))
        let data = DocxWriter.data(for: doc)
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil)
        XCTAssertTrue(text.string.contains("Big Title"))
        XCTAssertTrue(text.string.contains("Hello bold & <escaped> 中文"))
        XCTAssertTrue(text.string.contains("Second page"))
    }

    func testZipEntriesAreReadableByUnzip() throws {
        var zip = ZipWriter()
        zip.add("a.txt", text: String(repeating: "kumquat ", count: 200))
        zip.add("dir/b.bin", data: Data((0..<255).map { UInt8($0) }), compress: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try zip.finish().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "unzip -t reported a corrupt archive")
    }

    func testMarkdownRoundTripKeepsStructure() {
        let md = "# Title\n\nSome **bold** and *italic* text with a [link](https://example.com).\n\n- one\n- two\n"
        let attributed = MarkdownBridge.attributedString(fromMarkdown: md)
        let back = MarkdownBridge.markdown(from: attributed)
        XCTAssertTrue(back.contains("# Title"), back)
        XCTAssertTrue(back.contains("**bold**"), back)
        XCTAssertTrue(back.contains("*italic*"), back)
        XCTAssertTrue(back.contains("[link](https://example.com)"), back)
        XCTAssertTrue(back.contains("- one"), back)
    }
}

final class ImageToolTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func gradient(width: Int = 320, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        GradientPreset.all[0].draw(in: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testQuantizedPNGDecodesAndStaysClose() throws {
        let image = gradient()
        let buffer = try XCTUnwrap(RGBABuffer(image: image))
        let data = PNGQuantizer.pngData(PNGQuantizer.quantize(buffer))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let back = try XCTUnwrap(RGBABuffer(image: decoded))
        XCTAssertEqual(back.width, 320)
        var error = 0.0
        for i in stride(from: 0, to: buffer.pixels.count, by: 4) {
            for c in 0..<3 { error += pow(Double(back.pixels[i + c]) - Double(buffer.pixels[i + c]), 2) }
        }
        let psnr = 10 * log10(255 * 255 / (error / Double(buffer.pixels.count / 4 * 3)))
        XCTAssertGreaterThan(psnr, 30, "quantized image is too far from the original")
    }

    func testStrippingRemovesLocationAndCameraData() throws {
        let url = dir.appendingPathComponent("Photo.jpg")
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Kumquat Camera", kCGImagePropertyTIFFModel: "K1"],
        ]
        try ImageIOHelpers.write(gradient(), to: url, type: .jpeg, properties: props)
        let before = try ImageMetadata.summary(of: url)
        XCTAssertTrue(before.hasLocation)

        let noLocation = try ImageMetadata.strip(url, mode: .location)
        XCTAssertFalse(try ImageMetadata.summary(of: noLocation).hasLocation)

        let clean = try ImageMetadata.strip(url, mode: .everything)
        let props2 = ImageIOHelpers.properties(try ImageIOHelpers.source(clean))
        XCTAssertNil(props2[kCGImagePropertyGPSDictionary])
        XCTAssertNil((props2[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertEqual(ImageIOHelpers.orientation(props2), .right, "orientation must survive so the photo stays upright")
    }

    func testCropAndBackgroundSizes() throws {
        let image = gradient(width: 400, height: 300)
        let cropped = try XCTUnwrap(ImageCrop.crop(image, to: CGRect(x: 10, y: 20, width: 100, height: 50)))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 50)

        var params = BackgroundParams.defaults(for: CGSize(width: 400, height: 300))
        params.padding = 50
        params.ratio = .auto
        XCTAssertEqual(BackgroundComposer.compose(image, params: params)?.width, 500)
        params.ratio = .square
        let square = try XCTUnwrap(BackgroundComposer.compose(image, params: params))
        XCTAssertEqual(square.width, square.height)
    }

    func testRedactionBlacksOutTheRegion() throws {
        let image = gradient(width: 200, height: 200)
        let redacted = try XCTUnwrap(Redactor.redact(image, regions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], style: .blackout))
        let buffer = try XCTUnwrap(RGBABuffer(image: redacted))
        let center = (100 * 200 + 100) * 4
        XCTAssertEqual(Array(buffer.pixels[center..<center + 3]), [0, 0, 0])
        let corner = (5 * 200 + 5) * 4
        XCTAssertNotEqual(Array(buffer.pixels[corner..<corner + 3]), [0, 0, 0])
    }

    func testEditRotationSwapsDimensions() throws {
        var adj = ImageAdjustments()
        adj.quarterTurns = 1
        adj.exposure = 0.3
        let out = try XCTUnwrap(ImageAdjuster.apply(adj, to: gradient(width: 320, height: 200)))
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 320)
    }
}

final class PDFRenderTests: XCTestCase {
    /// A page with /Rotate 90 must come out landscape → portrait, with the page's left edge on top.
    func testRotatedPagesRenderUpright() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 200)) // red strip along the left edge
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try XCTUnwrap(PDFDocument(url: url))
        doc.page(at: 0)?.rotation = 90
        XCTAssertTrue(doc.write(to: url))

        let page = try XCTUnwrap(PDFRenderer.document(at: url).page(at: 1))
        let image = try XCTUnwrap(PDFRenderer.render(page, dpi: 72))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 400)
        let pixels = try XCTUnwrap(RGBABuffer(image: image))
        let top = (5 * 200 + 100) * 4, bottom = (395 * 200 + 100) * 4
        XCTAssertGreaterThan(pixels.pixels[top], 200)      // red on top
        XCTAssertLessThan(pixels.pixels[top + 1], 60)
        XCTAssertGreaterThan(pixels.pixels[bottom + 1], 200) // white at the bottom
    }
}
