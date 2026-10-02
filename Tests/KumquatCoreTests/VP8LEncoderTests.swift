import ImageIO
import XCTest
@testable import KumquatCore

final class VP8LEncoderTests: XCTestCase {
    /// Deterministic pseudo-random generator so failures are reproducible.
    struct LCG {
        var state: UInt64
        mutating func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
    }

    static func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> RGBABuffer {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = a
            }
        }
        return RGBABuffer(width: width, height: height, pixels: pixels)
    }

    func decode(_ data: Data) throws -> RGBABuffer {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil), "ImageIO could not decode the WebP")
        return try XCTUnwrap(RGBABuffer(image: image))
    }

    func assertRoundTrip(_ buffer: RGBABuffer, tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try VP8LEncoder.encode(buffer)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF", file: file, line: line)
        let decoded = try decode(data)
        XCTAssertEqual(decoded.width, buffer.width, file: file, line: line)
        XCTAssertEqual(decoded.height, buffer.height, file: file, line: line)
        var mismatches = 0
        for i in stride(from: 0, to: buffer.pixels.count, by: 4) {
            let a = Int(buffer.pixels[i + 3])
            if abs(Int(decoded.pixels[i + 3]) - a) > 0 { mismatches += 1; continue }
            if a == 0 { continue }
            // ImageIO premultiplies on decode, so translucent colours can drift by rounding.
            let slack = a == 255 ? tolerance : max(tolerance, 255 / a + 1)
            for c in 0..<3 where abs(Int(decoded.pixels[i + c]) - Int(buffer.pixels[i + c])) > slack {
                mismatches += 1
                break
            }
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches) pixels differ", file: file, line: line)
    }

    func testSmoothGradient() throws {
        try assertRoundTrip(Self.makeImage(width: 300, height: 200) { x, y in
            (UInt8(x * 255 / 299), UInt8(y * 255 / 199), UInt8((x + y) % 256), 255)
        })
    }

    func testNoise() throws {
        var rng = LCG(state: 42)
        try assertRoundTrip(Self.makeImage(width: 97, height: 61) { _, _ in
            (rng.next(), rng.next(), rng.next(), 255)
        })
    }

    func testPhotoLikeWithNoiseAndEdges() throws {
        var rng = LCG(state: 7)
        try assertRoundTrip(Self.makeImage(width: 640, height: 480) { x, y in
            let base = (x / 40 + y / 40) % 2 == 0 ? 180 : 60
            let n = Int(rng.next() % 9) - 4
            let v = UInt8(clamping: base + n + x / 8)
            return (v, UInt8(clamping: Int(v) + 20), UInt8(clamping: 255 - Int(v)), 255)
        })
    }

    func testTwoColours() throws {
        try assertRoundTrip(Self.makeImage(width: 33, height: 17) { x, y in
            (x + y) % 3 == 0 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        })
    }

    func testFourColours() throws {
        try assertRoundTrip(Self.makeImage(width: 50, height: 9) { x, y in
            let c = UInt8(((x / 3) + y) % 4) * 60
            return (c, 255 - c, c / 2, 255)
        })
    }

    func testSixteenColours() throws {
        try assertRoundTrip(Self.makeImage(width: 129, height: 40) { x, y in
            let c = UInt8((x ^ y) % 16) * 16
            return (c, c, 255 - c, 255)
        })
    }

    func testTwoHundredColours() throws {
        try assertRoundTrip(Self.makeImage(width: 200, height: 100) { x, _ in
            (UInt8(x), UInt8(x / 2), 9, 255)
        })
    }

    func testAlpha() throws {
        try assertRoundTrip(Self.makeImage(width: 120, height: 80) { x, y in
            let a = UInt8(clamping: (x * 3 + y) % 256)
            return (200, UInt8(y * 3), UInt8(x * 2), a)
        })
    }

    func testBinaryAlphaWithManyColours() throws {
        try assertRoundTrip(Self.makeImage(width: 400, height: 300) { x, y in
            let inside = (x - 200) * (x - 200) + (y - 150) * (y - 150) < 120 * 120
            return (UInt8(x % 256), UInt8(y % 256), 128, inside ? 255 : 0)
        })
    }

    func testTinyImages() throws {
        try assertRoundTrip(Self.makeImage(width: 1, height: 1) { _, _ in (10, 20, 30, 255) })
        try assertRoundTrip(Self.makeImage(width: 1, height: 9) { _, y in (UInt8(y * 20), 0, 0, 255) })
        try assertRoundTrip(Self.makeImage(width: 9, height: 1) { x, _ in (0, UInt8(x * 20), 0, 255) })
        var rng = LCG(state: 3)
        try assertRoundTrip(Self.makeImage(width: 3, height: 7) { _, _ in (rng.next(), rng.next(), rng.next(), 255) })
    }

    func testSolidColour() throws {
        try assertRoundTrip(Self.makeImage(width: 256, height: 256) { _, _ in (255, 128, 0, 255) })
    }

    func testLongRunsAndRepeats() throws {
        // Repeated rows exercise the "pixel above" distance code; stripes exercise long copies.
        var rng = LCG(state: 11)
        let row = (0..<500).map { _ in (rng.next(), rng.next(), rng.next()) }
        try assertRoundTrip(Self.makeImage(width: 500, height: 120) { x, y in
            y % 10 < 5 ? (row[x].0, row[x].1, row[x].2, 255) : (UInt8(y), 0, 0, 255)
        })
    }

    func testPrefixEncoding() {
        // Decoder formula from the VP8L spec.
        func decode(_ symbol: Int, _ extra: Int) -> Int {
            if symbol < 4 { return symbol + 1 }
            let extraBits = (symbol - 2) >> 1
            let offset = (2 + (symbol & 1)) << extraBits
            return offset + extra + 1
        }
        for value in 1...5000 {
            let e = VP8LEncoder.prefixEncode(value)
            XCTAssertEqual(decode(e.symbol, e.extra), value)
            XCTAssertLessThan(e.extra, 1 << max(e.extraBits, 0) + (e.extraBits == 0 ? 1 : 0))
        }
        XCTAssertEqual(VP8LEncoder.prefixEncode(4096).symbol, 23)
    }
}
