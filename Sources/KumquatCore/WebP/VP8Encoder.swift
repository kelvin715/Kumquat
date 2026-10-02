import Foundation

/// Lossy WebP (a single VP8 key frame).
///
/// Each 16×16 macroblock picks the best of the four whole-block intra predictors (DC, V, H, TM)
/// for luma and for chroma, transforms the residual with 4×4 DCTs (luma DC through a second-order
/// Walsh–Hadamard block), quantizes it and codes the tokens with the boolean entropy coder,
/// updating the coefficient probabilities to fit the image. Reconstruction mirrors the decoder
/// exactly, so later predictions see the same pixels the decoder will.
public enum VP8Encoder {
    /// `quality` is 0...1, like the JPEG quality slider.
    public static func encode(_ buffer: RGBABuffer, quality: Double) throws -> Data {
        let width = buffer.width, height = buffer.height
        guard width > 0, height > 0, width <= 16383, height <= 16383 else {
            throw KumquatError.encodeFailed("WebP (images larger than 16383 px aren't supported)")
        }
        var frame = Frame(buffer: buffer, quantizer: quantizerIndex(for: quality))
        frame.encodeMacroblocks()
        let vp8 = frame.bitstream(filterLevel: filterLevel(for: frame.quantizer))
        return riff(vp8)
    }

    /// Maps quality to a quantizer index (0 = finest, 127 = coarsest).
    static func quantizerIndex(for quality: Double) -> Int {
        let q = min(max(quality, 0), 1)
        return Int((pow(1 - q, 0.8) * 127).rounded())
    }

    /// Deblocking strength grows with the quantizer.
    static func filterLevel(for quantizer: Int) -> Int {
        min(63, Int((Double(quantizer) * 0.4).rounded()))
    }

    static func riff(_ payload: [UInt8]) -> Data {
        var data = Data()
        let padded = payload.count + (payload.count & 1)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE32(UInt32(4 + 8 + padded))
        data.append(contentsOf: Array("WEBP".utf8))
        data.append(contentsOf: Array("VP8 ".utf8))
        data.appendLE32(UInt32(payload.count))
        data.append(contentsOf: payload)
        if payload.count & 1 == 1 { data.append(0) }
        return data
    }
}

// MARK: - Boolean entropy coder (RFC 6386, section 7)

struct VP8BoolEncoder {
    private(set) var output: [UInt8] = []
    private var range: UInt32 = 255
    private var bottom: UInt32 = 0
    private var bitCount = 24

    init(capacity: Int = 4096) {
        output.reserveCapacity(capacity)
    }

    private mutating func carry() {
        var i = output.count - 1
        while i >= 0 && output[i] == 255 {
            output[i] = 0
            i -= 1
        }
        if i >= 0 { output[i] += 1 }
    }

    /// Writes `bit` whose probability of being 0 is `probability`/256.
    @inline(__always)
    mutating func put(_ bit: Bool, _ probability: UInt8) {
        let split = 1 + (((range - 1) &* UInt32(probability)) >> 8)
        if bit {
            bottom = bottom &+ split
            range -= split
        } else {
            range = split
        }
        while range < 128 {
            range <<= 1
            if bottom & (1 << 31) != 0 { carry() }
            bottom <<= 1
            bitCount -= 1
            if bitCount == 0 {
                output.append(UInt8(truncatingIfNeeded: bottom >> 24))
                bottom &= (1 << 24) - 1
                bitCount = 8
            }
        }
    }

    /// Unsigned literal, most significant bit first, each bit at probability 1/2.
    mutating func putLiteral(_ value: Int, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            put((value >> i) & 1 == 1, 128)
        }
    }

    mutating func finish() -> [UInt8] {
        var c = bitCount
        var v = bottom
        if v & (UInt32(1) << UInt32(32 - c)) != 0 { carry() }
        v <<= UInt32(c & 7)
        c >>= 3
        while c > 0 {
            v <<= 8
            c -= 1
        }
        for _ in 0..<4 {
            output.append(UInt8(truncatingIfNeeded: v >> 24))
            v <<= 8
        }
        return output
    }
}

// MARK: - Frame encoder

private struct Frame {
    // Prediction modes, in VP8 numbering.
    static let dcPred = 0, vPred = 1, hPred = 2, tmPred = 3

    // Token indices.
    static let zeroToken = 0, oneToken = 1, eobToken = 11

    let width: Int, height: Int
    let mbWidth: Int, mbHeight: Int
    let quantizer: Int

    // Source and reconstruction planes, padded to whole macroblocks.
    var srcY: [UInt8], srcU: [UInt8], srcV: [UInt8]
    var recY: [UInt8], recU: [UInt8], recV: [UInt8]
    let yStride: Int, uvStride: Int

    // Quantizer steps.
    let y1DC: Int32, y1AC: Int32, y2DC: Int32, y2AC: Int32, uvDC: Int32, uvAC: Int32

    // Per-macroblock decisions.
    var yModes: [UInt8]
    var uvModes: [UInt8]
    var skipped: [Bool]

    /// Coded tokens in decoding order. Each entry packs:
    /// probability context (type, band, ctx) | token | skip-EOB flag | sign | extra value.
    var tokens: [UInt32] = []
    /// Number of tokens belonging to each macroblock (0 for skipped ones).
    var tokenCounts: [Int]

    // Above / left "has non-zero coefficients" contexts: 4 Y + 2 U + 2 V + 1 Y2.
    var aboveContext: [UInt8]
    var leftContext = [UInt8](repeating: 0, count: 9)

    init(buffer: RGBABuffer, quantizer: Int) {
        width = buffer.width
        height = buffer.height
        mbWidth = (width + 15) / 16
        mbHeight = (height + 15) / 16
        self.quantizer = quantizer
        yStride = mbWidth * 16
        uvStride = mbWidth * 8
        let yCount = yStride * mbHeight * 16
        let uvCount = uvStride * mbHeight * 8
        srcY = [UInt8](repeating: 0, count: yCount)
        srcU = [UInt8](repeating: 0, count: uvCount)
        srcV = [UInt8](repeating: 0, count: uvCount)
        recY = srcY
        recU = srcU
        recV = srcV

        func dc(_ q: Int) -> Int32 { VP8Tables.dcQuantizer[min(max(q, 0), 127)] }
        func ac(_ q: Int) -> Int32 { VP8Tables.acQuantizer[min(max(q, 0), 127)] }
        y1DC = dc(quantizer)
        y1AC = ac(quantizer)
        y2DC = dc(quantizer) * 2
        y2AC = max(8, ac(quantizer) * 155 / 100)
        uvDC = min(dc(quantizer), 132)
        uvAC = ac(quantizer)

        let mbCount = mbWidth * mbHeight
        yModes = [UInt8](repeating: 0, count: mbCount)
        uvModes = [UInt8](repeating: 0, count: mbCount)
        skipped = [Bool](repeating: false, count: mbCount)
        tokenCounts = [Int](repeating: 0, count: mbCount)
        aboveContext = [UInt8](repeating: 0, count: mbWidth * 9)
        tokens.reserveCapacity(mbCount * 64)
        convertColors(buffer)
    }

    /// BT.601 limited-range YUV 4:2:0 (full-precision coefficients, rounded once), edges
    /// replicated into the padding. Chroma is converted from the average of each 2×2 block.
    mutating func convertColors(_ buffer: RGBABuffer) {
        let px = buffer.pixels
        let w = width, h = height
        @inline(__always) func luma(_ r: Double, _ g: Double, _ b: Double) -> UInt8 {
            UInt8(clamping: Int((16 + (65.481 * r + 128.553 * g + 24.966 * b) / 255).rounded()))
        }
        for y in 0..<(mbHeight * 16) {
            let sy = min(y, h - 1)
            for x in 0..<(mbWidth * 16) {
                let i = 4 * (sy * w + min(x, w - 1))
                srcY[y * yStride + x] = luma(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
            }
        }
        for y in 0..<(mbHeight * 8) {
            for x in 0..<(mbWidth * 8) {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 {
                    let sy = min(2 * y + dy, h - 1)
                    for dx in 0..<2 {
                        let i = 4 * (sy * w + min(2 * x + dx, w - 1))
                        r += Double(px[i])
                        g += Double(px[i + 1])
                        b += Double(px[i + 2])
                    }
                }
                r /= 4
                g /= 4
                b /= 4
                let u = 128 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255
                let v = 128 + (112.0 * r - 93.786 * g - 18.214 * b) / 255
                srcU[y * uvStride + x] = UInt8(clamping: Int(u.rounded()))
                srcV[y * uvStride + x] = UInt8(clamping: Int(v.rounded()))
            }
        }
    }

    // MARK: Prediction (exactly as the decoder does it)

    /// Fills `out` (n×n) with the prediction for a block at (x0, y0) of a reconstructed plane.
    static func predict(_ plane: [UInt8], stride: Int, x0: Int, y0: Int, n: Int, mode: Int, into out: inout [Int32]) {
        let hasAbove = y0 > 0, hasLeft = x0 > 0
        @inline(__always) func above(_ i: Int) -> Int32 { hasAbove ? Int32(plane[(y0 - 1) * stride + x0 + i]) : 127 }
        @inline(__always) func left(_ i: Int) -> Int32 { hasLeft ? Int32(plane[(y0 + i) * stride + x0 - 1]) : 129 }
        switch mode {
        case dcPred:
            let shift: Int32 = n == 16 ? 4 : 3
            var value: Int32 = 128
            if hasAbove && hasLeft {
                var sum: Int32 = 0
                for i in 0..<n { sum += above(i) + left(i) }
                value = (sum + Int32(n)) >> (shift + 1)
            } else if hasAbove {
                var sum: Int32 = 0
                for i in 0..<n { sum += above(i) }
                value = (sum + Int32(n / 2)) >> shift
            } else if hasLeft {
                var sum: Int32 = 0
                for i in 0..<n { sum += left(i) }
                value = (sum + Int32(n / 2)) >> shift
            }
            for i in 0..<(n * n) { out[i] = value }
        case vPred:
            for r in 0..<n { for c in 0..<n { out[r * n + c] = above(c) } }
        case hPred:
            for r in 0..<n {
                let l = left(r)
                for c in 0..<n { out[r * n + c] = l }
            }
        default: // TM
            let corner: Int32 = (hasAbove && hasLeft) ? Int32(plane[(y0 - 1) * stride + x0 - 1]) : (hasAbove ? 129 : 127)
            for r in 0..<n {
                let l = left(r)
                for c in 0..<n { out[r * n + c] = min(max(l + above(c) - corner, 0), 255) }
            }
        }
    }

    // MARK: Transforms

    /// Forward 4×4 DCT scaled to match the decoder's inverse (twice the orthonormal DCT).
    static let dctBasis: [Double] = {
        var basis = [Double](repeating: 0, count: 16)
        for k in 0..<4 {
            let scale: Double = k == 0 ? 0.5 : 0.7071067811865476
            for n in 0..<4 {
                let angle: Double = Double((2 * n + 1) * k) * Double.pi / 8.0
                basis[k * 4 + n] = scale * cos(angle)
            }
        }
        return basis
    }()

    @inline(__always)
    static func forwardDCT(_ residual: UnsafePointer<Int32>, _ out: UnsafeMutablePointer<Int32>) {
        let b = dctBasis
        var tmp = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            for k in 0..<4 {
                var s = 0.0
                for n in 0..<4 { s += b[k * 4 + n] * Double(residual[r * 4 + n]) }
                tmp[r * 4 + k] = s
            }
        }
        for c in 0..<4 {
            for k in 0..<4 {
                var s = 0.0
                for n in 0..<4 { s += b[k * 4 + n] * tmp[n * 4 + c] }
                out[k * 4 + c] = Int32((2 * s).rounded())
            }
        }
    }

    /// The decoder's inverse DCT, added onto the prediction (RFC 6386, section 14.4).
    @inline(__always)
    static func inverseDCTAdd(_ coeffs: UnsafePointer<Int32>, prediction: UnsafePointer<Int32>, output: UnsafeMutablePointer<Int32>) {
        let c1k: Int32 = 20091, s1k: Int32 = 35468
        var tmp = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let a1 = coeffs[i] + coeffs[8 + i]
            let b1 = coeffs[i] - coeffs[8 + i]
            var t1 = (coeffs[4 + i] * s1k) >> 16
            var t2 = coeffs[12 + i] + ((coeffs[12 + i] * c1k) >> 16)
            let c1 = t1 - t2
            t1 = coeffs[4 + i] + ((coeffs[4 + i] * c1k) >> 16)
            t2 = (coeffs[12 + i] * s1k) >> 16
            let d1 = t1 + t2
            tmp[i] = a1 + d1
            tmp[12 + i] = a1 - d1
            tmp[4 + i] = b1 + c1
            tmp[8 + i] = b1 - c1
        }
        for r in 0..<4 {
            let row = r * 4
            let a1 = tmp[row] + tmp[row + 2]
            let b1 = tmp[row] - tmp[row + 2]
            var t1 = (tmp[row + 1] * s1k) >> 16
            var t2 = tmp[row + 3] + ((tmp[row + 3] * c1k) >> 16)
            let c1 = t1 - t2
            t1 = tmp[row + 1] + ((tmp[row + 1] * c1k) >> 16)
            t2 = (tmp[row + 3] * s1k) >> 16
            let d1 = t1 + t2
            output[row] = min(max(prediction[row] + ((a1 + d1 + 4) >> 3), 0), 255)
            output[row + 3] = min(max(prediction[row + 3] + ((a1 - d1 + 4) >> 3), 0), 255)
            output[row + 1] = min(max(prediction[row + 1] + ((b1 + c1 + 4) >> 3), 0), 255)
            output[row + 2] = min(max(prediction[row + 2] + ((b1 - c1 + 4) >> 3), 0), 255)
        }
    }

    /// Forward Walsh–Hadamard transform of the 16 luma DC values: (M·D·M)/2 with the decoder's M.
    static func forwardWHT(_ dc: [Int32]) -> [Int32] {
        let m: [Int32] = [1, 1, 1, 1, 1, 1, -1, -1, 1, -1, -1, 1, 1, -1, 1, -1]
        var t = [Int32](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 {
                var s: Int32 = 0
                for k in 0..<4 { s += m[r * 4 + k] * dc[k * 4 + c] }
                t[r * 4 + c] = s
            }
        }
        var out = [Int32](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 {
                var s: Int32 = 0
                for k in 0..<4 { s += t[r * 4 + k] * m[k * 4 + c] }
                out[r * 4 + c] = s >= 0 ? (s + 1) / 2 : -((-s + 1) / 2)
            }
        }
        return out
    }

    /// The decoder's inverse Walsh–Hadamard transform (RFC 6386, section 14.3).
    static func inverseWHT(_ input: [Int32]) -> [Int32] {
        var out = [Int32](repeating: 0, count: 16)
        for i in 0..<4 {
            let a1 = input[i] + input[12 + i]
            let b1 = input[4 + i] + input[8 + i]
            let c1 = input[4 + i] - input[8 + i]
            let d1 = input[i] - input[12 + i]
            out[i] = a1 + b1
            out[4 + i] = c1 + d1
            out[8 + i] = a1 - b1
            out[12 + i] = d1 - c1
        }
        for r in 0..<4 {
            let p = r * 4
            let a1 = out[p] + out[p + 3]
            let b1 = out[p + 1] + out[p + 2]
            let c1 = out[p + 1] - out[p + 2]
            let d1 = out[p] - out[p + 3]
            let a2 = a1 + b1, b2 = c1 + d1, c2 = a1 - b1, d2 = d1 - c1
            out[p] = (a2 + 3) >> 3
            out[p + 1] = (b2 + 3) >> 3
            out[p + 2] = (c2 + 3) >> 3
            out[p + 3] = (d2 + 3) >> 3
        }
        return out
    }

    @inline(__always)
    static func quantize(_ value: Int32, step: Int32, deadZone: Double) -> Int32 {
        let magnitude = Int32((Double(abs(value)) / Double(step) + 0.5 - deadZone).rounded(.down))
        let level = min(max(magnitude, 0), 2048)
        return value < 0 ? -level : level
    }

    // MARK: Macroblocks

    mutating func encodeMacroblocks() {
        var prediction = [Int32](repeating: 0, count: 256)
        var best = [Int32](repeating: 0, count: 256)
        var predU = [Int32](repeating: 0, count: 64), predV = [Int32](repeating: 0, count: 64)
        var bestU = predU, bestV = predV

        for mby in 0..<mbHeight {
            leftContext = [UInt8](repeating: 0, count: 9)
            for mbx in 0..<mbWidth {
                let mb = mby * mbWidth + mbx
                let x0 = mbx * 16, y0 = mby * 16

                // Luma mode: smallest squared error against the source.
                var bestError = Int64.max
                var yMode = Frame.dcPred
                for mode in 0..<4 {
                    Frame.predict(recY, stride: yStride, x0: x0, y0: y0, n: 16, mode: mode, into: &prediction)
                    var error: Int64 = 0
                    for r in 0..<16 {
                        let row = (y0 + r) * yStride + x0
                        for c in 0..<16 {
                            let d = Int64(srcY[row + c]) - Int64(prediction[r * 16 + c])
                            error += d * d
                        }
                    }
                    if error < bestError {
                        bestError = error
                        yMode = mode
                        best = prediction
                    }
                }

                // Chroma mode, U and V together.
                var bestChroma = Int64.max
                var uvMode = Frame.dcPred
                for mode in 0..<4 {
                    Frame.predict(recU, stride: uvStride, x0: mbx * 8, y0: mby * 8, n: 8, mode: mode, into: &predU)
                    Frame.predict(recV, stride: uvStride, x0: mbx * 8, y0: mby * 8, n: 8, mode: mode, into: &predV)
                    var error: Int64 = 0
                    for r in 0..<8 {
                        let row = (mby * 8 + r) * uvStride + mbx * 8
                        for c in 0..<8 {
                            let du = Int64(srcU[row + c]) - Int64(predU[r * 8 + c])
                            let dv = Int64(srcV[row + c]) - Int64(predV[r * 8 + c])
                            error += du * du + dv * dv
                        }
                    }
                    if error < bestChroma {
                        bestChroma = error
                        uvMode = mode
                        bestU = predU
                        bestV = predV
                    }
                }
                yModes[mb] = UInt8(yMode)
                uvModes[mb] = UInt8(uvMode)

                encodeMacroblock(mb: mb, mbx: mbx, mby: mby, yPrediction: best, uPrediction: bestU, vPrediction: bestV)
            }
        }
    }

    /// Transforms, quantizes, reconstructs and tokenizes one macroblock.
    mutating func encodeMacroblock(mb: Int, mbx: Int, mby: Int, yPrediction: [Int32], uPrediction: [Int32], vPrediction: [Int32]) {
        let x0 = mbx * 16, y0 = mby * 16
        var yLevels = [Int32](repeating: 0, count: 256)  // 16 blocks × 16 coefficients (raster in block)
        var y2Levels = [Int32](repeating: 0, count: 16)
        var uvLevels = [Int32](repeating: 0, count: 128)  // 4 U blocks then 4 V blocks
        var residual = [Int32](repeating: 0, count: 16)
        var coeffs = [Int32](repeating: 0, count: 16)
        var dcValues = [Int32](repeating: 0, count: 16)

        // Luma: DCT each 4×4 block, gather the DCs for the Y2 block.
        for b in 0..<16 {
            let bx = (b & 3) * 4, by = (b >> 2) * 4
            for r in 0..<4 {
                for c in 0..<4 {
                    residual[r * 4 + c] = Int32(srcY[(y0 + by + r) * yStride + x0 + bx + c]) - yPrediction[(by + r) * 16 + bx + c]
                }
            }
            residual.withUnsafeBufferPointer { res in
                coeffs.withUnsafeMutableBufferPointer { co in Frame.forwardDCT(res.baseAddress!, co.baseAddress!) }
            }
            dcValues[b] = coeffs[0]
            for i in 1..<16 {
                yLevels[b * 16 + i] = Frame.quantize(coeffs[i], step: y1AC, deadZone: 0.15)
            }
        }
        let y2 = Frame.forwardWHT(dcValues)
        for i in 0..<16 {
            y2Levels[i] = Frame.quantize(y2[i], step: i == 0 ? y2DC : y2AC, deadZone: 0.05)
        }

        // Chroma.
        for plane in 0..<2 {
            let src = plane == 0 ? srcU : srcV
            let pred = plane == 0 ? uPrediction : vPrediction
            for b in 0..<4 {
                let bx = (b & 1) * 4, by = (b >> 1) * 4
                for r in 0..<4 {
                    for c in 0..<4 {
                        residual[r * 4 + c] = Int32(src[(mby * 8 + by + r) * uvStride + mbx * 8 + bx + c]) - pred[(by + r) * 8 + bx + c]
                    }
                }
                residual.withUnsafeBufferPointer { res in
                    coeffs.withUnsafeMutableBufferPointer { co in Frame.forwardDCT(res.baseAddress!, co.baseAddress!) }
                }
                for i in 0..<16 {
                    uvLevels[(plane * 4 + b) * 16 + i] = Frame.quantize(coeffs[i], step: i == 0 ? uvDC : uvAC, deadZone: i == 0 ? 0.05 : 0.15)
                }
            }
        }

        let isEmpty = y2Levels.allSatisfy { $0 == 0 } && yLevels.allSatisfy { $0 == 0 } && uvLevels.allSatisfy { $0 == 0 }
        skipped[mb] = isEmpty

        reconstruct(mbx: mbx, mby: mby, yPrediction: yPrediction, uPrediction: uPrediction, vPrediction: vPrediction,
                    yLevels: yLevels, y2Levels: y2Levels, uvLevels: uvLevels)

        // Tokens (a skipped macroblock codes none and clears its contexts, as the decoder does).
        let ctxBase = mbx * 9
        if isEmpty {
            for i in 0..<9 {
                aboveContext[ctxBase + i] = 0
                leftContext[i] = 0
            }
            tokenCounts[mb] = 0
            return
        }
        let start = tokens.count
        // Y2 (type 1)
        let y2NZ = tokenize(levels: y2Levels, offset: 0, type: 1, firstCoefficient: 0,
                            context: Int(aboveContext[ctxBase + 8] + leftContext[8]))
        aboveContext[ctxBase + 8] = y2NZ
        leftContext[8] = y2NZ
        // 16 Y blocks (type 0, starting at coefficient 1)
        for b in 0..<16 {
            let ax = b & 3, ly = b >> 2
            let nz = tokenize(levels: yLevels, offset: b * 16, type: 0, firstCoefficient: 1,
                              context: Int(aboveContext[ctxBase + ax] + leftContext[ly]))
            aboveContext[ctxBase + ax] = nz
            leftContext[ly] = nz
        }
        // 4 U then 4 V blocks (type 2)
        for plane in 0..<2 {
            for b in 0..<4 {
                let ax = 4 + plane * 2 + (b & 1), ly = 4 + plane * 2 + (b >> 1)
                let nz = tokenize(levels: uvLevels, offset: (plane * 4 + b) * 16, type: 2, firstCoefficient: 0,
                                  context: Int(aboveContext[ctxBase + ax] + leftContext[ly]))
                aboveContext[ctxBase + ax] = nz
                leftContext[ly] = nz
            }
        }
        tokenCounts[mb] = tokens.count - start
    }

    /// Rebuilds the macroblock exactly as a decoder will, into the reconstruction planes.
    mutating func reconstruct(mbx: Int, mby: Int, yPrediction: [Int32], uPrediction: [Int32], vPrediction: [Int32],
                              yLevels: [Int32], y2Levels: [Int32], uvLevels: [Int32]) {
        var dequantY2 = [Int32](repeating: 0, count: 16)
        for i in 0..<16 { dequantY2[i] = y2Levels[i] * (i == 0 ? y2DC : y2AC) }
        let dcs = Frame.inverseWHT(dequantY2)
        var coeffs = [Int32](repeating: 0, count: 16)
        var pred = [Int32](repeating: 0, count: 16)
        var out = [Int32](repeating: 0, count: 16)
        let x0 = mbx * 16, y0 = mby * 16

        for b in 0..<16 {
            let bx = (b & 3) * 4, by = (b >> 2) * 4
            coeffs[0] = dcs[b]
            for i in 1..<16 { coeffs[i] = yLevels[b * 16 + i] * y1AC }
            for r in 0..<4 { for c in 0..<4 { pred[r * 4 + c] = yPrediction[(by + r) * 16 + bx + c] } }
            coeffs.withUnsafeBufferPointer { co in
                pred.withUnsafeBufferPointer { pr in
                    out.withUnsafeMutableBufferPointer { o in Frame.inverseDCTAdd(co.baseAddress!, prediction: pr.baseAddress!, output: o.baseAddress!) }
                }
            }
            for r in 0..<4 { for c in 0..<4 { recY[(y0 + by + r) * yStride + x0 + bx + c] = UInt8(out[r * 4 + c]) } }
        }
        for plane in 0..<2 {
            let predPlane = plane == 0 ? uPrediction : vPrediction
            for b in 0..<4 {
                let bx = (b & 1) * 4, by = (b >> 1) * 4
                for i in 0..<16 { coeffs[i] = uvLevels[(plane * 4 + b) * 16 + i] * (i == 0 ? uvDC : uvAC) }
                for r in 0..<4 { for c in 0..<4 { pred[r * 4 + c] = predPlane[(by + r) * 8 + bx + c] } }
                coeffs.withUnsafeBufferPointer { co in
                    pred.withUnsafeBufferPointer { pr in
                        out.withUnsafeMutableBufferPointer { o in Frame.inverseDCTAdd(co.baseAddress!, prediction: pr.baseAddress!, output: o.baseAddress!) }
                    }
                }
                for r in 0..<4 {
                    for c in 0..<4 {
                        let index = (mby * 8 + by + r) * uvStride + mbx * 8 + bx + c
                        if plane == 0 { recU[index] = UInt8(out[r * 4 + c]) } else { recV[index] = UInt8(out[r * 4 + c]) }
                    }
                }
            }
        }
    }

    // MARK: Tokens

    /// Appends one block's tokens; returns 1 if the block has any non-zero coefficient.
    mutating func tokenize(levels: [Int32], offset: Int, type: Int, firstCoefficient: Int, context: Int) -> UInt8 {
        var last = -1
        for i in stride(from: 15, through: firstCoefficient, by: -1) where levels[offset + VP8Tables.zigzag[i]] != 0 {
            last = i
            break
        }
        var ctx = context
        var afterZero = false
        if last < 0 {
            tokens.append(Frame.pack(type: type, band: VP8Tables.bands[firstCoefficient], ctx: ctx,
                                     token: Frame.eobToken, skipEOB: false, negative: false, extra: 0))
            return 0
        }
        for i in firstCoefficient...last {
            let value = levels[offset + VP8Tables.zigzag[i]]
            let magnitude = Int(abs(value))
            let (token, extra) = Frame.token(for: magnitude)
            tokens.append(Frame.pack(type: type, band: VP8Tables.bands[i], ctx: ctx, token: token,
                                     skipEOB: afterZero, negative: value < 0, extra: extra))
            afterZero = token == Frame.zeroToken
            ctx = magnitude == 0 ? 0 : (magnitude == 1 ? 1 : 2)
        }
        if last < 15 {
            tokens.append(Frame.pack(type: type, band: VP8Tables.bands[last + 1], ctx: ctx,
                                     token: Frame.eobToken, skipEOB: false, negative: false, extra: 0))
        }
        return 1
    }

    /// Token index (0 = ZERO … 4 = FOUR, 5…10 = categories 1…6) and the category's extra value.
    static func token(for magnitude: Int) -> (Int, Int) {
        if magnitude <= 4 { return (magnitude, 0) }
        for cat in stride(from: 5, through: 0, by: -1) where magnitude >= VP8Tables.categoryBase[cat] {
            return (5 + cat, magnitude - VP8Tables.categoryBase[cat])
        }
        return (4, 0)
    }

    @inline(__always)
    static func pack(type: Int, band: Int, ctx: Int, token: Int, skipEOB: Bool, negative: Bool, extra: Int) -> UInt32 {
        let probIndex: UInt32 = UInt32((type * 8 + band) * 3 + ctx) // 0..<96
        var packed: UInt32 = (probIndex << 24) | (UInt32(token) << 20) | UInt32(extra)
        if skipEOB { packed |= 1 << 19 }
        if negative { packed |= 1 << 18 }
        return packed
    }

    /// Walks the token tree, reporting each (node, bit) decision.
    @inline(__always)
    static func forEachBranch(token: Int, skipEOB: Bool, _ visit: (Int, Bool) -> Void) {
        if !skipEOB { visit(0, token != eobToken) }
        if token == eobToken { return }
        visit(1, token != zeroToken)
        if token == zeroToken { return }
        visit(2, token != oneToken)
        if token == oneToken { return }
        if token <= 4 {
            visit(3, false)
            visit(4, token != 2)
            if token != 2 { visit(5, token == 4) }
            return
        }
        visit(3, true)
        if token <= 6 {
            visit(6, false)
            visit(7, token == 6)
        } else {
            visit(6, true)
            if token <= 8 {
                visit(8, false)
                visit(9, token == 8)
            } else {
                visit(8, true)
                visit(10, token == 10)
            }
        }
    }

    // MARK: Bitstream

    func bitstream(filterLevel: Int) -> [UInt8] {
        // Fit the coefficient probabilities to this image where that saves bits.
        var counts = [Int](repeating: 0, count: 96 * 11 * 2)
        for packed in tokens {
            let probIndex = Int(packed >> 24)
            let token = Int((packed >> 20) & 0xf)
            let skipEOB = packed & (1 << 19) != 0
            Frame.forEachBranch(token: token, skipEOB: skipEOB) { node, bit in
                counts[(probIndex * 11 + node) * 2 + (bit ? 1 : 0)] += 1
            }
        }
        var probabilities = VP8Tables.defaultCoefficientProbabilities
        var updated = [Bool](repeating: false, count: 1056)
        for i in 0..<1056 {
            let zeros = counts[i * 2], ones = counts[i * 2 + 1]
            let total = zeros + ones
            guard total > 0 else { continue }
            let fitted = UInt8(min(max((zeros * 256 + total / 2) / total, 1), 255))
            let old = probabilities[i]
            let updateProbability = VP8Tables.coefficientUpdateProbabilities[i]
            let savings = Frame.cost(zeros: zeros, ones: ones, probability: old)
                - Frame.cost(zeros: zeros, ones: ones, probability: fitted)
                - (Frame.bitCost(true, updateProbability) - Frame.bitCost(false, updateProbability)) - 8
            if savings > 0 && fitted != old {
                probabilities[i] = fitted
                updated[i] = true
            }
        }

        let mbCount = mbWidth * mbHeight
        let coded = skipped.filter { !$0 }.count
        let skipProbability = UInt8(min(max((coded * 256 + mbCount / 2) / max(mbCount, 1), 1), 255))

        // First partition: frame header and macroblock modes.
        var header = VP8BoolEncoder(capacity: mbCount / 2 + 2048)
        header.putLiteral(0, bits: 1)            // colour space: YUV
        header.putLiteral(0, bits: 1)            // clamping required
        header.putLiteral(0, bits: 1)            // no segmentation
        header.putLiteral(0, bits: 1)            // normal loop filter
        header.putLiteral(filterLevel, bits: 6)
        header.putLiteral(0, bits: 3)            // sharpness
        header.putLiteral(0, bits: 1)            // no mode/ref filter adjustments
        header.putLiteral(0, bits: 2)            // one token partition
        header.putLiteral(quantizer, bits: 7)
        for _ in 0..<5 { header.putLiteral(0, bits: 1) } // no quantizer deltas
        header.putLiteral(0, bits: 1)            // refresh_entropy_probs
        for i in 0..<1056 {
            header.put(updated[i], VP8Tables.coefficientUpdateProbabilities[i])
            if updated[i] { header.putLiteral(Int(probabilities[i]), bits: 8) }
        }
        header.putLiteral(1, bits: 1)            // per-macroblock skip flags
        header.putLiteral(Int(skipProbability), bits: 8)
        let yProbs = VP8Tables.keyFrameYModeProbabilities, uvProbs = VP8Tables.keyFrameUVModeProbabilities
        for mb in 0..<mbCount {
            header.put(skipped[mb], skipProbability)
            header.put(true, yProbs[0]) // not B_PRED
            switch Int(yModes[mb]) {
            case Frame.dcPred: header.put(false, yProbs[1]); header.put(false, yProbs[2])
            case Frame.vPred: header.put(false, yProbs[1]); header.put(true, yProbs[2])
            case Frame.hPred: header.put(true, yProbs[1]); header.put(false, yProbs[3])
            default: header.put(true, yProbs[1]); header.put(true, yProbs[3])
            }
            switch Int(uvModes[mb]) {
            case Frame.dcPred: header.put(false, uvProbs[0])
            case Frame.vPred: header.put(true, uvProbs[0]); header.put(false, uvProbs[1])
            case Frame.hPred: header.put(true, uvProbs[0]); header.put(true, uvProbs[1]); header.put(false, uvProbs[2])
            default: header.put(true, uvProbs[0]); header.put(true, uvProbs[1]); header.put(true, uvProbs[2])
            }
        }
        let firstPartition = header.finish()

        // Token partition.
        var residuals = VP8BoolEncoder(capacity: tokens.count + 1024)
        for packed in tokens {
            let probIndex = Int(packed >> 24)
            let token = Int((packed >> 20) & 0xf)
            let skipEOB = packed & (1 << 19) != 0
            let base = probIndex * 11
            Frame.forEachBranch(token: token, skipEOB: skipEOB) { node, bit in
                residuals.put(bit, probabilities[base + node])
            }
            if token == Frame.eobToken || token == Frame.zeroToken { continue }
            if token >= 5 {
                let category = token - 5
                let probs = VP8Tables.categoryProbabilities[category]
                let extra = Int(packed & 0x3ffff)
                for (k, p) in probs.enumerated() {
                    residuals.put((extra >> (probs.count - 1 - k)) & 1 == 1, p)
                }
            }
            residuals.put(packed & (1 << 18) != 0, 128)
        }
        let tokenPartition = residuals.finish()

        var out: [UInt8] = []
        out.reserveCapacity(firstPartition.count + tokenPartition.count + 10)
        // Key frame (bit 0 = 0), version 0, shown (bit 4), then the first partition's size.
        let partitionSize: UInt32 = UInt32(firstPartition.count)
        let tag: UInt32 = (1 << 4) | (partitionSize << 5)
        out.append(UInt8(tag & 0xff))
        out.append(UInt8((tag >> 8) & 0xff))
        out.append(UInt8((tag >> 16) & 0xff))
        out += [0x9d, 0x01, 0x2a]
        out.append(UInt8(width & 0xff))
        out.append(UInt8((width >> 8) & 0x3f))
        out.append(UInt8(height & 0xff))
        out.append(UInt8((height >> 8) & 0x3f))
        out += firstPartition
        out += tokenPartition
        return out
    }

    static let costTable: [Double] = {
        var table = [Double](repeating: 0, count: 257)
        for p in 1...256 {
            let fraction: Double = Double(p) / 256.0
            table[p] = -log2(fraction)
        }
        return table
    }()

    @inline(__always)
    static func bitCost(_ bit: Bool, _ probability: UInt8) -> Double {
        let p = Int(probability)
        return bit ? costTable[256 - p] : costTable[p]
    }

    static func cost(zeros: Int, ones: Int, probability: UInt8) -> Double {
        Double(zeros) * bitCost(false, probability) + Double(ones) * bitCost(true, probability)
    }
}
