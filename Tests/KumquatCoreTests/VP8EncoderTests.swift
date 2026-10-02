import ImageIO
import XCTest
@testable import KumquatCore

final class VP8EncoderTests: XCTestCase {
    func decode(_ data: Data) throws -> RGBABuffer {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil), "ImageIO could not decode the lossy WebP")
        return try XCTUnwrap(RGBABuffer(image: image))
    }

    func psnr(_ a: RGBABuffer, _ b: RGBABuffer) -> Double {
        var error = 0.0
        for i in stride(from: 0, to: a.pixels.count, by: 4) {
            for c in 0..<3 {
                let d = Double(a.pixels[i + c]) - Double(b.pixels[i + c])
                error += d * d
            }
        }
        let mse = error / Double(a.width * a.height * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    func roundTrip(_ image: RGBABuffer, quality: Double = 0.85, minimumPSNR: Double,
                   file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let data = try VP8Encoder.encode(image, quality: quality)
        XCTAssertEqual(String(decoding: data.subdata(in: 12..<16), as: UTF8.self), "VP8 ", file: file, line: line)
        let decoded = try decode(data)
        XCTAssertEqual(decoded.width, image.width, file: file, line: line)
        XCTAssertEqual(decoded.height, image.height, file: file, line: line)
        let quality = psnr(image, decoded)
        XCTAssertGreaterThan(quality, minimumPSNR, "PSNR \(quality) dB", file: file, line: line)
        return data
    }

    func testSmoothGradient() throws {
        let image = VP8LEncoderTests.makeImage(width: 320, height: 240) { x, y in
            (UInt8(x * 255 / 319), UInt8(y * 255 / 239), UInt8((x + y) / 3 % 256), 255)
        }
        _ = try roundTrip(image, minimumPSNR: 34)
    }

    /// Partial macroblocks at the right and bottom edges must decode in place.
    /// (Smooth content: sharp per-pixel colour changes are limited by 4:2:0 chroma, in libwebp too.)
    func testOddSizesAndEdges() throws {
        for (w, h) in [(1, 1), (17, 9), (33, 47), (100, 3)] {
            let image = VP8LEncoderTests.makeImage(width: w, height: h) { x, y in
                (UInt8(40 + x * 180 / max(w - 1, 1)), UInt8(200 - x * 120 / max(w - 1, 1)), UInt8(90 + y), 255)
            }
            _ = try roundTrip(image, quality: 0.95, minimumPSNR: 33)
        }
    }

    func testPhotoLikeContentCompressesWell() throws {
        var rng = VP8LEncoderTests.LCG(state: 5)
        let image = VP8LEncoderTests.makeImage(width: 512, height: 384) { x, y in
            let wave = 128 + 90 * sin(Double(x) / 23) * cos(Double(y) / 31)
            let n = Double(Int(rng.next() % 7) - 3)
            let v = UInt8(clamping: Int(wave + n))
            return (v, UInt8(clamping: Int(v) / 2 + 60), UInt8(clamping: 255 - Int(v)), 255)
        }
        let data = try roundTrip(image, minimumPSNR: 32)
        // Far smaller than lossless for photographic content.
        let lossless = try VP8LEncoder.encode(image)
        XCTAssertLessThan(data.count, lossless.count / 2)
    }

    func testFlatImageIsTiny() throws {
        let image = VP8LEncoderTests.makeImage(width: 640, height: 480) { _, _ in (240, 120, 30, 255) }
        let data = try roundTrip(image, minimumPSNR: 38)
        XCTAssertLessThan(data.count, 2000)
    }

    func testQualityControlsSize() throws {
        var rng = VP8LEncoderTests.LCG(state: 9)
        let image = VP8LEncoderTests.makeImage(width: 256, height: 256) { _, _ in (rng.next(), rng.next(), rng.next(), 255) }
        let low = try VP8Encoder.encode(image, quality: 0.3)
        let high = try VP8Encoder.encode(image, quality: 0.95)
        XCTAssertLessThan(low.count, high.count)
        XCTAssertNoThrow(try decode(low))
        XCTAssertNoThrow(try decode(high))
    }

    func testBoolEncoderRoundTripsThroughSpecDecoder() {
        // Decoder from RFC 6386 section 7, used to check the encoder bit for bit.
        var encoder = VP8BoolEncoder()
        var rng = VP8LEncoderTests.LCG(state: 77)
        var expected: [(Bool, UInt8)] = []
        for _ in 0..<5000 {
            let p = UInt8(max(1, Int(rng.next())))
            let bit = rng.next() < 100
            expected.append((bit, p))
            encoder.put(bit, p)
        }
        let bytes = encoder.finish()
        var value = (UInt32(bytes[0]) << 8) | UInt32(bytes[1])
        var input = 2
        var range: UInt32 = 255
        var bitCount = 0
        for (bit, p) in expected {
            let split = 1 + (((range - 1) * UInt32(p)) >> 8)
            let bigSplit = split << 8
            var decoded = false
            if value >= bigSplit {
                decoded = true
                range -= split
                value -= bigSplit
            } else {
                range = split
            }
            while range < 128 {
                value <<= 1
                range <<= 1
                bitCount += 1
                if bitCount == 8 {
                    bitCount = 0
                    value |= UInt32(input < bytes.count ? bytes[input] : 0)
                    input += 1
                }
            }
            XCTAssertEqual(decoded, bit)
            if decoded != bit { return }
        }
    }
}
