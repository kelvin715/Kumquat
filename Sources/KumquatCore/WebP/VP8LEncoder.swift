import Foundation

/// A self-contained WebP lossless (VP8L) encoder.
///
/// Implements the subtract-green, predictor and colour-indexing transforms, LZ77 backward
/// references, a colour cache and canonical prefix codes. Output decodes bit-exactly with
/// libwebp and ImageIO.
public enum VP8LEncoder {
    public struct Options: Sendable {
        /// Hash-chain candidates examined per pixel (higher = smaller and slower).
        public var searchDepth = 24
        public init() {}
    }

    public static func encode(_ buffer: RGBABuffer, options: Options = Options()) throws -> Data {
        let width = buffer.width, height = buffer.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw KumquatError.encodeFailed("WebP (images larger than 16384 px aren't supported)")
        }
        var argb = [UInt32](repeating: 0, count: width * height)
        let px = buffer.pixels
        var hasAlpha = false
        for i in 0..<(width * height) {
            let r = UInt32(px[4 * i]), g = UInt32(px[4 * i + 1]), b = UInt32(px[4 * i + 2]), a = UInt32(px[4 * i + 3])
            if a != 255 { hasAlpha = true }
            // Fully transparent pixels have no visible colour; zeroing it compresses better.
            argb[i] = a == 0 ? 0 : (a << 24) | (r << 16) | (g << 8) | b
        }

        var writer = VP8LBitWriter(capacity: width * height)
        writer.write(0x2f, 8)
        writer.write(width - 1, 14)
        writer.write(height - 1, 14)
        writer.write(hasAlpha ? 1 : 0, 1)
        writer.write(0, 3)

        var codedWidth = width
        if let palette = palette(of: argb, limit: 256) {
            // Colour-indexing transform: pixels become palette indices, bundled when the palette is small.
            writer.write(1, 1)
            writer.write(3, 2)
            writer.write(palette.count - 1, 8)
            var deltas = [UInt32](repeating: 0, count: palette.count)
            for i in 0..<palette.count {
                deltas[i] = i == 0 ? palette[0] : subPixels(palette[i], palette[i - 1])
            }
            writeSubImage(deltas, width: palette.count, height: 1, into: &writer)
            let bits = palette.count <= 2 ? 3 : palette.count <= 4 ? 2 : palette.count <= 16 ? 1 : 0
            (argb, codedWidth) = bundle(argb, width: width, height: height, palette: palette, widthBits: bits)
        } else {
            // Subtract-green, then spatial prediction.
            writer.write(1, 1)
            writer.write(2, 2)
            for i in 0..<argb.count {
                let p = argb[i]
                let g = (p >> 8) & 0xff
                let r = (((p >> 16) & 0xff) &- g) & 0xff
                let b = ((p & 0xff) &- g) & 0xff
                argb[i] = (p & 0xff00_ff00) | (r << 16) | b
            }
            let blockBits = (width * height >= 256 * 256) ? 4 : 3
            writer.write(1, 1)
            writer.write(0, 2)
            writer.write(blockBits - 2, 3)
            let (residuals, modes, modesWidth, modesHeight) = predict(argb, width: width, height: height, blockBits: blockBits)
            writeSubImage(modes, width: modesWidth, height: modesHeight, into: &writer)
            argb = residuals
        }
        writer.write(0, 1) // no more transforms

        let copies = backwardReferences(argb, width: codedWidth, searchDepth: options.searchDepth)
        let cacheBits = bestCacheBits(argb, copies: copies, width: codedWidth)
        writeImageData(argb, copies: copies, width: codedWidth, cacheBits: cacheBits,
                       isMainImage: true, into: &writer)

        let payload = writer.finish()
        return riff(payload)
    }

    // MARK: - Container

    static func riff(_ payload: [UInt8]) -> Data {
        var data = Data()
        let padded = payload.count + (payload.count & 1)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(&data, UInt32(4 + 8 + padded))
        data.append(contentsOf: Array("WEBP".utf8))
        data.append(contentsOf: Array("VP8L".utf8))
        appendLE32(&data, UInt32(payload.count))
        data.append(contentsOf: payload)
        if payload.count & 1 == 1 { data.append(0) }
        return data
    }

    static func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xff))
        data.append(UInt8((v >> 8) & 0xff))
        data.append(UInt8((v >> 16) & 0xff))
        data.append(UInt8((v >> 24) & 0xff))
    }

    // MARK: - Pixel arithmetic

    @inline(__always)
    static func subPixels(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let alpha = (((a >> 24) &- (b >> 24)) & 0xff) << 24
        let red = ((((a >> 16) & 0xff) &- ((b >> 16) & 0xff)) & 0xff) << 16
        let green = ((((a >> 8) & 0xff) &- ((b >> 8) & 0xff)) & 0xff) << 8
        let blue = ((a & 0xff) &- (b & 0xff)) & 0xff
        return alpha | red | green | blue
    }

    @inline(__always)
    static func average2(_ a: UInt32, _ b: UInt32) -> UInt32 {
        (((a ^ b) & 0xfefe_fefe) >> 1) &+ (a & b)
    }

    @inline(__always)
    static func channel(_ p: UInt32, _ shift: UInt32) -> Int { Int((p >> shift) & 0xff) }

    @inline(__always)
    static func clamp255(_ v: Int) -> UInt32 { UInt32(v < 0 ? 0 : (v > 255 ? 255 : v)) }

    @inline(__always)
    static func select(left: UInt32, top: UInt32, topLeft: UInt32) -> UInt32 {
        // Distance of the gradient estimate (L + T - TL) from L is |T - TL|, from T is |L - TL|.
        @inline(__always) func score(_ a: UInt32, _ b: UInt32) -> Int {
            abs(channel(a, 24) - channel(b, 24)) + abs(channel(a, 16) - channel(b, 16))
                + abs(channel(a, 8) - channel(b, 8)) + abs(channel(a, 0) - channel(b, 0))
        }
        return score(top, topLeft) < score(left, topLeft) ? left : top
    }

    @inline(__always)
    static func clampAddSubtractFull(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        @inline(__always) func lane(_ s: UInt32) -> UInt32 {
            clamp255(channel(a, s) + channel(b, s) - channel(c, s)) << s
        }
        return lane(24) | lane(16) | lane(8) | lane(0)
    }

    @inline(__always)
    static func clampAddSubtractHalf(_ a: UInt32, _ b: UInt32) -> UInt32 {
        @inline(__always) func lane(_ s: UInt32) -> UInt32 {
            let x = channel(a, s), y = channel(b, s)
            return clamp255(x + (x - y) / 2) << s
        }
        return lane(24) | lane(16) | lane(8) | lane(0)
    }

    @inline(__always)
    static func predictor(_ mode: Int, left: UInt32, top: UInt32, topRight: UInt32, topLeft: UInt32) -> UInt32 {
        switch mode {
        case 0: return 0xff00_0000
        case 1: return left
        case 2: return top
        case 3: return topRight
        case 4: return topLeft
        case 5: return average2(average2(left, topRight), top)
        case 6: return average2(left, topLeft)
        case 7: return average2(left, top)
        case 8: return average2(topLeft, top)
        case 9: return average2(top, topRight)
        case 10: return average2(average2(left, topLeft), average2(top, topRight))
        case 11: return select(left: left, top: top, topLeft: topLeft)
        case 12: return clampAddSubtractFull(left, top, topLeft)
        default: return clampAddSubtractHalf(average2(left, top), topLeft)
        }
    }

    /// Approximate bit cost of a residual byte (small magnitudes are cheap).
    static let residualCost: [Float] = (0..<256).map { v in
        let magnitude = v < 128 ? v : 256 - v
        return magnitude == 0 ? 0 : Float(log2(Double(magnitude)) + 1.5)
    }

    // MARK: - Predictor transform

    static func predict(_ image: [UInt32], width: Int, height: Int, blockBits: Int)
        -> (residuals: [UInt32], modes: [UInt32], modesWidth: Int, modesHeight: Int)
    {
        let block = 1 << blockBits
        let tilesX = (width + block - 1) >> blockBits
        let tilesY = (height + block - 1) >> blockBits
        var modes = [UInt32](repeating: 0xff00_0000, count: tilesX * tilesY)
        var residuals = [UInt32](repeating: 0, count: image.count)
        let cost = residualCost
        // Large photos: score every other row when choosing modes; it barely changes the choice.
        let rowStep = width * height > 4_000_000 ? 2 : 1

        image.withUnsafeBufferPointer { img in
            for ty in 0..<tilesY {
                for tx in 0..<tilesX {
                    let x0 = tx << blockBits, y0 = ty << blockBits
                    let x1 = min(x0 + block, width), y1 = min(y0 + block, height)
                    var bestMode = 11
                    var bestCost = Float.greatestFiniteMagnitude
                    for mode in 0..<14 {
                        var total: Float = 0
                        for y in stride(from: y0, to: y1, by: rowStep) {
                            for x in x0..<x1 {
                                let pos = y * width + x
                                let predicted: UInt32
                                if y == 0 {
                                    predicted = x == 0 ? 0xff00_0000 : img[pos - 1]
                                } else if x == 0 {
                                    predicted = img[pos - width]
                                } else {
                                    predicted = predictor(mode, left: img[pos - 1], top: img[pos - width],
                                                          topRight: img[pos - width + 1], topLeft: img[pos - width - 1])
                                }
                                let r = subPixels(img[pos], predicted)
                                total += cost[Int(r >> 24)] + cost[Int((r >> 16) & 0xff)]
                                    + cost[Int((r >> 8) & 0xff)] + cost[Int(r & 0xff)]
                            }
                            if total >= bestCost { break }
                        }
                        if total < bestCost {
                            bestCost = total
                            bestMode = mode
                        }
                    }
                    modes[ty * tilesX + tx] = 0xff00_0000 | (UInt32(bestMode) << 8)
                }
            }

            for y in 0..<height {
                for x in 0..<width {
                    let pos = y * width + x
                    let predicted: UInt32
                    if y == 0 {
                        predicted = x == 0 ? 0xff00_0000 : img[pos - 1]
                    } else if x == 0 {
                        predicted = img[pos - width]
                    } else {
                        let mode = Int((modes[(y >> blockBits) * tilesX + (x >> blockBits)] >> 8) & 0xff)
                        predicted = predictor(mode, left: img[pos - 1], top: img[pos - width],
                                              topRight: img[pos - width + 1], topLeft: img[pos - width - 1])
                    }
                    residuals[pos] = subPixels(img[pos], predicted)
                }
            }
        }
        return (residuals, modes, tilesX, tilesY)
    }

    // MARK: - Colour indexing

    static func palette(of image: [UInt32], limit: Int) -> [UInt32]? {
        var seen = Set<UInt32>()
        seen.reserveCapacity(limit + 1)
        for p in image {
            if seen.insert(p).inserted && seen.count > limit { return nil }
        }
        // Sorting keeps neighbouring entries similar, which makes the delta-coded table cheaper.
        return seen.sorted()
    }

    static func bundle(_ image: [UInt32], width: Int, height: Int, palette: [UInt32], widthBits: Int)
        -> ([UInt32], Int)
    {
        var index = [UInt32: UInt32]()
        for (i, color) in palette.enumerated() { index[color] = UInt32(i) }
        let perPixel = 1 << widthBits
        let bitsPerIndex = 8 >> widthBits
        let packedWidth = (width + perPixel - 1) >> widthBits
        var out = [UInt32](repeating: 0, count: packedWidth * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = index[image[y * width + x]] ?? 0
                let slot = y * packedWidth + (x >> widthBits)
                let shift = UInt32((x & (perPixel - 1)) * bitsPerIndex)
                out[slot] |= idx << shift
            }
        }
        for i in 0..<out.count { out[i] = 0xff00_0000 | (out[i] << 8) }
        return (out, packedWidth)
    }

    // MARK: - LZ77

    /// A backward reference. Pixels not covered by a copy are coded as literals.
    struct Copy {
        var start: Int32
        var length: Int32
        var distance: Int32
    }

    static let maxLength = 4096
    static let maxDistance = (1 << 20) - 120

    static func backwardReferences(_ image: [UInt32], width: Int, searchDepth: Int) -> [Copy] {
        let n = image.count
        var copies: [Copy] = []
        guard n > 2 else { return copies }
        let hashBits = 18
        var head = [Int32](repeating: -1, count: 1 << hashBits)
        var chain = [Int32](repeating: -1, count: n)

        image.withUnsafeBufferPointer { img in
            @inline(__always) func hash(_ i: Int) -> Int {
                var h = img[i] &* 0x1e35_a7bd
                h ^= img[i + 1] &* 0x9e37_79b1
                return Int(h >> UInt32(32 - hashBits))
            }
            @inline(__always) func insert(_ i: Int) {
                guard i + 1 < n else { return }
                let h = hash(i)
                chain[i] = head[h]
                head[h] = Int32(i)
            }
            @inline(__always) func matchLength(_ a: Int, _ b: Int, _ limit: Int) -> Int {
                var len = 0
                while len < limit && img[a + len] == img[b + len] { len += 1 }
                return len
            }

            var i = 0
            while i < n {
                let limit = min(maxLength, n - i)
                var bestLength = 0
                var bestDistance = 0
                if limit >= 3 {
                    // The pixel to the left and the one above are the cheapest distances to code.
                    if i >= 1 {
                        let len = matchLength(i, i - 1, limit)
                        if len > bestLength { bestLength = len; bestDistance = 1 }
                    }
                    if width > 1 && i >= width {
                        let len = matchLength(i, i - width, limit)
                        if len > bestLength { bestLength = len; bestDistance = width }
                    }
                    if bestLength < limit && i + 1 < n {
                        var candidate = Int(head[hash(i)])
                        var depth = 0
                        while candidate >= 0 && depth < searchDepth {
                            let d = i - candidate
                            if d > maxDistance { break }
                            if bestLength == 0 || img[candidate + bestLength] == img[i + bestLength] {
                                let len = matchLength(i, candidate, limit)
                                // Prefer longer matches, but far references cost more bits.
                                if len > bestLength + (d > bestDistance * 64 ? 1 : 0) {
                                    bestLength = len
                                    bestDistance = d
                                    if len == limit { break }
                                }
                            }
                            candidate = Int(chain[candidate])
                            depth += 1
                        }
                    }
                }
                if bestLength >= 3 {
                    copies.append(Copy(start: Int32(i), length: Int32(bestLength), distance: Int32(bestDistance)))
                    for k in 0..<bestLength { insert(i + k) }
                    i += bestLength
                } else {
                    insert(i)
                    i += 1
                }
            }
        }
        return copies
    }

    /// Maps a pixel distance to a VP8L distance code, using the short 2D codes for the
    /// four nearest neighbours (above, left, above-left, above-right).
    @inline(__always)
    static func distanceCode(_ distance: Int, width: Int) -> Int {
        if distance == width { return 1 }
        if distance == 1 { return 2 }
        if distance == width + 1 { return 3 }
        if distance == width - 1 && width > 1 { return 4 }
        return distance + 120
    }

    /// Splits a value ≥ 1 into its prefix symbol and extra bits.
    @inline(__always)
    static func prefixEncode(_ value: Int) -> (symbol: Int, extraBits: Int, extra: Int) {
        let d = value - 1
        if d < 4 { return (d, 0, 0) }
        let highest = (Int.bitWidth - 1) - d.leadingZeroBitCount
        let second = (d >> (highest - 1)) & 1
        let extraBits = highest - 1
        return (2 * highest + second, extraBits, d & ((1 << extraBits) - 1))
    }

    // MARK: - Colour cache

    @inline(__always)
    static func cacheIndex(_ argb: UInt32, bits: Int) -> Int {
        Int((argb &* 0x1e35_a7bd) >> UInt32(32 - bits))
    }

    /// Picks the colour-cache size with the lowest estimated cost.
    static func bestCacheBits(_ image: [UInt32], copies: [Copy], width: Int) -> Int {
        var best = 0
        var bestCost = Double.greatestFiniteMagnitude
        for bits in [0, 4, 6, 8, 10] {
            let h = histograms(image, copies: copies, width: width, cacheBits: bits)
            let cost = entropy(h.green) + entropy(h.red) + entropy(h.blue) + entropy(h.alpha)
                + entropy(h.distance) + Double(h.extraBits)
            if cost < bestCost {
                bestCost = cost
                best = bits
            }
        }
        return best
    }

    struct Histograms {
        var green: [Int]
        var red = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var alpha = [Int](repeating: 0, count: 256)
        var distance = [Int](repeating: 0, count: 40)
        var extraBits = 0

        init(cacheBits: Int) {
            green = [Int](repeating: 0, count: 256 + 24 + (cacheBits > 0 ? 1 << cacheBits : 0))
        }
    }

    /// One decoded unit of the image stream, in decoder order.
    enum Symbol {
        case literal(UInt32)
        case cacheHit(Int)
        case copy(length: Int, distance: Int)
    }

    /// Walks the image exactly as the decoder will, maintaining the colour cache.
    @inline(__always)
    static func forEachSymbol(_ image: [UInt32], copies: [Copy], cacheBits: Int, _ body: (Symbol) -> Void) {
        var cache = [UInt32](repeating: 0, count: cacheBits > 0 ? 1 << cacheBits : 0)
        let n = image.count
        var pos = 0
        var next = 0
        while pos < n {
            if next < copies.count && Int(copies[next].start) == pos {
                let c = copies[next]
                let length = Int(c.length)
                body(.copy(length: length, distance: Int(c.distance)))
                if cacheBits > 0 {
                    for k in 0..<length {
                        let p = image[pos + k]
                        cache[cacheIndex(p, bits: cacheBits)] = p
                    }
                }
                pos += length
                next += 1
            } else {
                let p = image[pos]
                if cacheBits > 0 {
                    let idx = cacheIndex(p, bits: cacheBits)
                    if cache[idx] == p {
                        body(.cacheHit(idx))
                    } else {
                        body(.literal(p))
                        cache[idx] = p
                    }
                } else {
                    body(.literal(p))
                }
                pos += 1
            }
        }
    }

    static func histograms(_ image: [UInt32], copies: [Copy], width: Int, cacheBits: Int) -> Histograms {
        var h = Histograms(cacheBits: cacheBits)
        forEachSymbol(image, copies: copies, cacheBits: cacheBits) { symbol in
            switch symbol {
            case .literal(let p):
                h.green[Int((p >> 8) & 0xff)] += 1
                h.red[Int((p >> 16) & 0xff)] += 1
                h.blue[Int(p & 0xff)] += 1
                h.alpha[Int(p >> 24)] += 1
            case .cacheHit(let idx):
                h.green[280 + idx] += 1
            case .copy(let length, let distance):
                let len = prefixEncode(length)
                h.green[256 + len.symbol] += 1
                let dist = prefixEncode(distanceCode(distance, width: width))
                h.distance[dist.symbol] += 1
                h.extraBits += len.extraBits + dist.extraBits
            }
        }
        return h
    }

    static func entropy(_ counts: [Int]) -> Double {
        var total = 0
        var used = 0
        for c in counts where c > 0 {
            total += c
            used += 1
        }
        guard total > 0 else { return 0 }
        var bits = 0.0
        let t = Double(total)
        for c in counts where c > 0 {
            bits -= Double(c) * log2(Double(c) / t)
        }
        // Rough cost of describing the code itself.
        return bits + Double(used) * 2
    }

    // MARK: - Writing

    static func writeSubImage(_ image: [UInt32], width: Int, height: Int, into writer: inout VP8LBitWriter) {
        let copies = backwardReferences(image, width: width, searchDepth: 8)
        writeImageData(image, copies: copies, width: width, cacheBits: 0, isMainImage: false, into: &writer)
    }

    static func writeImageData(_ image: [UInt32], copies: [Copy], width: Int, cacheBits: Int,
                               isMainImage: Bool, into writer: inout VP8LBitWriter) {
        if cacheBits > 0 {
            writer.write(1, 1)
            writer.write(cacheBits, 4)
        } else {
            writer.write(0, 1)
        }
        if isMainImage { writer.write(0, 1) } // a single prefix-code group for the whole image

        let h = histograms(image, copies: copies, width: width, cacheBits: cacheBits)
        let green = PrefixCode(counts: h.green)
        let red = PrefixCode(counts: h.red)
        let blue = PrefixCode(counts: h.blue)
        let alpha = PrefixCode(counts: h.alpha)
        let distance = PrefixCode(counts: h.distance)
        for code in [green, red, blue, alpha, distance] {
            writeCode(code, into: &writer)
        }

        forEachSymbol(image, copies: copies, cacheBits: cacheBits) { symbol in
            switch symbol {
            case .literal(let p):
                green.write(Int((p >> 8) & 0xff), to: &writer)
                red.write(Int((p >> 16) & 0xff), to: &writer)
                blue.write(Int(p & 0xff), to: &writer)
                alpha.write(Int(p >> 24), to: &writer)
            case .cacheHit(let idx):
                green.write(280 + idx, to: &writer)
            case .copy(let length, let dist):
                let len = prefixEncode(length)
                green.write(256 + len.symbol, to: &writer)
                writer.write(len.extra, len.extraBits)
                let d = prefixEncode(distanceCode(dist, width: width))
                distance.write(d.symbol, to: &writer)
                writer.write(d.extra, d.extraBits)
            }
        }
    }

    static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Writes a prefix code's description: the compact "simple" form when possible,
    /// otherwise run-length coded code lengths.
    static func writeCode(_ code: PrefixCode, into writer: inout VP8LBitWriter) {
        let used = code.lengths.indices.filter { code.lengths[$0] > 0 }
        if used.count <= 2 && used.allSatisfy({ $0 < 256 }) {
            writer.write(1, 1) // simple code
            let symbols = used.isEmpty ? [0] : used
            writer.write(symbols.count - 1, 1)
            if symbols[0] < 2 {
                writer.write(0, 1)
                writer.write(symbols[0], 1)
            } else {
                writer.write(1, 1)
                writer.write(symbols[0], 8)
            }
            if symbols.count == 2 { writer.write(symbols[1], 8) }
            return
        }

        writer.write(0, 1) // normal code
        // Run-length tokens: (symbol, extra bit count, extra value).
        var tokens: [(symbol: Int, bits: Int, value: Int)] = []
        let lengths = code.lengths.map(Int.init)
        var i = 0
        while i < lengths.count {
            let value = lengths[i]
            var run = 1
            while i + run < lengths.count && lengths[i + run] == value { run += 1 }
            i += run
            if value == 0 {
                var left = run
                while left >= 11 {
                    let r = min(left, 138)
                    tokens.append((18, 7, r - 11))
                    left -= r
                }
                if left >= 3 {
                    tokens.append((17, 3, left - 3))
                    left = 0
                }
                while left > 0 {
                    tokens.append((0, 0, 0))
                    left -= 1
                }
            } else {
                tokens.append((value, 0, 0))
                var left = run - 1
                while left >= 3 {
                    let r = min(left, 6)
                    tokens.append((16, 2, r - 3))
                    left -= r
                }
                while left > 0 {
                    tokens.append((value, 0, 0))
                    left -= 1
                }
            }
        }

        var counts = [Int](repeating: 0, count: 19)
        for t in tokens { counts[t.symbol] += 1 }
        let lengthCode = PrefixCode(counts: counts, maxLength: 7)
        var count = 19
        while count > 4 && lengthCode.lengths[codeLengthOrder[count - 1]] == 0 { count -= 1 }
        writer.write(count - 4, 4)
        for k in 0..<count {
            writer.write(Int(lengthCode.lengths[codeLengthOrder[k]]), 3)
        }
        writer.write(0, 1) // the code lengths cover the whole alphabet
        for t in tokens {
            lengthCode.write(t.symbol, to: &writer)
            writer.write(t.value, t.bits)
        }
    }
}
