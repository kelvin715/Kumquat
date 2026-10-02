import Compression
import Foundation

/// Reduces an RGBA image to an indexed palette of at most 256 colours (median cut, refined
/// with k-means, Floyd–Steinberg dithering) and writes it as an 8-bit indexed PNG.
/// This is the same idea as pngquant / TinyPNG.
public enum PNGQuantizer {
    public struct Result {
        public var palette: [UInt32] // RGBA, R in the top byte
        public var indices: [UInt8]
        public var width: Int
        public var height: Int
    }

    public static func quantize(_ buffer: RGBABuffer, maxColors: Int = 256, dither: Float = 0.75) -> Result {
        let w = buffer.width, h = buffer.height
        let px = buffer.pixels
        let n = w * h

        // Exact palette when the image already has few colours.
        var exact: [UInt32: Int] = [:]
        for i in 0..<n {
            let c = pack(px[4 * i], px[4 * i + 1], px[4 * i + 2], px[4 * i + 3])
            if exact[c] == nil {
                exact[c] = exact.count
                if exact.count > maxColors { break }
            }
        }
        if exact.count <= maxColors {
            var palette = [UInt32](repeating: 0, count: exact.count)
            for (c, i) in exact { palette[i] = c }
            var indices = [UInt8](repeating: 0, count: n)
            for i in 0..<n {
                indices[i] = UInt8(exact[pack(px[4 * i], px[4 * i + 1], px[4 * i + 2], px[4 * i + 3])]!)
            }
            return Result(palette: palette, indices: indices, width: w, height: h)
        }

        // Histogram at 5 bits per channel (alpha at 4 bits).
        var histogram: [UInt32: (count: Int, r: Int, g: Int, b: Int, a: Int)] = [:]
        for i in 0..<n {
            let r = px[4 * i], g = px[4 * i + 1], b = px[4 * i + 2], a = px[4 * i + 3]
            let key = bucketKey(r, g, b, a)
            var e = histogram[key] ?? (0, 0, 0, 0, 0)
            e.count += 1
            e.r += Int(r); e.g += Int(g); e.b += Int(b); e.a += Int(a)
            histogram[key] = e
        }
        var entries: [ColorEntry] = histogram.values.map {
            ColorEntry(r: Float($0.r) / Float($0.count), g: Float($0.g) / Float($0.count),
                       b: Float($0.b) / Float($0.count), a: Float($0.a) / Float($0.count), count: $0.count)
        }

        var palette = medianCut(&entries, colors: maxColors)
        palette = refine(palette, entries: entries, iterations: 3)

        var lookup = [Int16](repeating: -1, count: 1 << 19)
        let packedPalette = palette.map { pack(clampByte($0.r), clampByte($0.g), clampByte($0.b), clampByte($0.a)) }

        func nearest(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> Int {
            let key = Int(clampByte(r) >> 3) << 14 | Int(clampByte(g) >> 3) << 9 | Int(clampByte(b) >> 3) << 4
                | Int(clampByte(a) >> 4)
            if lookup[key] >= 0 { return Int(lookup[key]) }
            var best = 0
            var bestDistance = Float.greatestFiniteMagnitude
            for (i, p) in palette.enumerated() {
                let dr = p.r - r, dg = p.g - g, db = p.b - b, da = p.a - a
                let d = dr * dr * 0.5 + dg * dg + db * db * 0.35 + da * da * 1.5
                if d < bestDistance {
                    bestDistance = d
                    best = i
                }
            }
            lookup[key] = Int16(best)
            return best
        }

        // Floyd–Steinberg error diffusion on two rows of error buffers.
        var indices = [UInt8](repeating: 0, count: n)
        var current = [Float](repeating: 0, count: (w + 2) * 4)
        var next = [Float](repeating: 0, count: (w + 2) * 4)
        for y in 0..<h {
            for i in 0..<next.count { next[i] = 0 }
            for x in 0..<w {
                let p = 4 * (y * w + x)
                let e = 4 * (x + 1)
                let r = Float(px[p]) + current[e]
                let g = Float(px[p + 1]) + current[e + 1]
                let b = Float(px[p + 2]) + current[e + 2]
                let a = Float(px[p + 3]) + current[e + 3]
                let index = nearest(r, g, b, a)
                indices[y * w + x] = UInt8(index)
                guard dither > 0 else { continue }
                let chosen = palette[index]
                @inline(__always) func spread(_ c: Int, _ error: Float) {
                    current[e + 4 + c] += error * (7 / 16)
                    next[e - 4 + c] += error * (3 / 16)
                    next[e + c] += error * (5 / 16)
                    next[e + 4 + c] += error * (1 / 16)
                }
                spread(0, (r - chosen.r) * dither)
                spread(1, (g - chosen.g) * dither)
                spread(2, (b - chosen.b) * dither)
                spread(3, (a - chosen.a) * dither)
            }
            swap(&current, &next)
        }
        return Result(palette: packedPalette, indices: indices, width: w, height: h)
    }

    // MARK: - Median cut

    struct ColorEntry {
        var r, g, b, a: Float
        var count: Int

        func value(_ channel: Int) -> Float {
            switch channel {
            case 0: return r
            case 1: return g
            case 2: return b
            default: return a
            }
        }
    }

    struct PaletteColor {
        var r, g, b, a: Float
    }

    static func medianCut(_ entries: inout [ColorEntry], colors: Int) -> [PaletteColor] {
        var boxes: [Range<Int>] = [0..<entries.count]
        while boxes.count < colors {
            // Split the box with the most pixels times its widest range.
            var bestBox = -1
            var bestScore: Float = 0
            var bestChannel = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                var lo: [Float] = [255, 255, 255, 255], hi: [Float] = [0, 0, 0, 0]
                var population = 0
                for k in box {
                    let e = entries[k]
                    population += e.count
                    for c in 0..<4 {
                        let v = e.value(c)
                        lo[c] = min(lo[c], v)
                        hi[c] = max(hi[c], v)
                    }
                }
                let weights: [Float] = [0.7, 1, 0.5, 1.2]
                var channel = 0
                var range: Float = 0
                for c in 0..<4 where (hi[c] - lo[c]) * weights[c] > range {
                    range = (hi[c] - lo[c]) * weights[c]
                    channel = c
                }
                let score = range * Float(population).squareRoot()
                if score > bestScore {
                    bestScore = score
                    bestBox = i
                    bestChannel = channel
                }
            }
            guard bestBox >= 0 else { break }
            let box = boxes[bestBox]
            entries[box].sort { $0.value(bestChannel) < $1.value(bestChannel) }
            let total = entries[box].reduce(0) { $0 + $1.count }
            var running = 0
            var split = box.lowerBound + 1
            for k in box {
                running += entries[k].count
                if running * 2 >= total {
                    split = min(max(k + 1, box.lowerBound + 1), box.upperBound - 1)
                    break
                }
            }
            boxes[bestBox] = box.lowerBound..<split
            boxes.append(split..<box.upperBound)
        }
        return boxes.map { box in
            var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0, count: Float = 0
            for k in box {
                let e = entries[k]
                let c = Float(e.count)
                r += e.r * c; g += e.g * c; b += e.b * c; a += e.a * c
                count += c
            }
            return PaletteColor(r: r / count, g: g / count, b: b / count, a: a / count)
        }
    }

    /// A few rounds of k-means over the histogram entries.
    static func refine(_ palette: [PaletteColor], entries: [ColorEntry], iterations: Int) -> [PaletteColor] {
        var palette = palette
        for _ in 0..<iterations {
            var sums = [(r: Float, g: Float, b: Float, a: Float, n: Float)](repeating: (0, 0, 0, 0, 0), count: palette.count)
            for e in entries {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (i, p) in palette.enumerated() {
                    let dr = p.r - e.r, dg = p.g - e.g, db = p.b - e.b, da = p.a - e.a
                    let d = dr * dr * 0.5 + dg * dg + db * db * 0.35 + da * da * 1.5
                    if d < bestDistance {
                        bestDistance = d
                        best = i
                    }
                }
                let c = Float(e.count)
                sums[best].r += e.r * c; sums[best].g += e.g * c; sums[best].b += e.b * c; sums[best].a += e.a * c
                sums[best].n += c
            }
            for i in palette.indices where sums[i].n > 0 {
                palette[i] = PaletteColor(r: sums[i].r / sums[i].n, g: sums[i].g / sums[i].n,
                                          b: sums[i].b / sums[i].n, a: sums[i].a / sums[i].n)
            }
        }
        return palette
    }

    @inline(__always)
    static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }

    @inline(__always)
    static func bucketKey(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
        UInt32(r >> 3) << 15 | UInt32(g >> 3) << 10 | UInt32(b >> 3) << 5 | UInt32(a >> 4)
    }

    @inline(__always)
    static func clampByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    // MARK: - PNG output

    public static func pngData(_ result: Result) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.appendBE32(UInt32(result.width))
        ihdr.appendBE32(UInt32(result.height))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0]) // 8-bit, indexed, deflate, adaptive filtering, no interlace
        appendChunk(&data, "IHDR", ihdr)

        var plte = Data()
        var alphas: [UInt8] = []
        for c in result.palette {
            plte.append(UInt8(c >> 24))
            plte.append(UInt8((c >> 16) & 0xff))
            plte.append(UInt8((c >> 8) & 0xff))
            alphas.append(UInt8(c & 0xff))
        }
        appendChunk(&data, "PLTE", plte)
        while alphas.last == 255 { alphas.removeLast() }
        if !alphas.isEmpty { appendChunk(&data, "tRNS", Data(alphas)) }

        var raw = Data(capacity: (result.width + 1) * result.height)
        for y in 0..<result.height {
            raw.append(0) // filter: none (best for indexed images)
            raw.append(contentsOf: result.indices[(y * result.width)..<((y + 1) * result.width)])
        }
        appendChunk(&data, "IDAT", zlib(raw))
        appendChunk(&data, "IEND", Data())
        return data
    }

    static func appendChunk(_ data: inout Data, _ type: String, _ body: Data) {
        data.appendBE32(UInt32(body.count))
        var chunk = Data(type.utf8)
        chunk.append(body)
        data.append(chunk)
        data.appendBE32(CRC32.checksum(chunk))
    }

    /// zlib stream (RFC 1950): header + raw deflate + Adler-32.
    static func zlib(_ raw: Data) -> Data {
        var out = Data([0x78, 0x9C])
        out.append(ZipWriter.deflate(raw) ?? storedDeflate(raw))
        var a: UInt32 = 1, b: UInt32 = 0
        raw.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                a = (a + UInt32(byte)) % 65521
                b = (b + a) % 65521
            }
        }
        out.appendBE32(b << 16 | a)
        return out
    }

    /// Uncompressed deflate blocks, used only if the compressor fails.
    static func storedDeflate(_ raw: Data) -> Data {
        var out = Data()
        var offset = 0
        repeat {
            let size = min(65535, raw.count - offset)
            let last: UInt8 = offset + size >= raw.count ? 1 : 0
            out.append(last)
            out.appendLE16(UInt16(size))
            out.appendLE16(~UInt16(size))
            out.append(raw[raw.startIndex + offset..<raw.startIndex + offset + size])
            offset += size
        } while offset < raw.count
        return out
    }
}
