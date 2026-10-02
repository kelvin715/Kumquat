import Foundation

/// Little-endian bit writer used by the WebP lossless (VP8L) bitstream: values are packed
/// starting from the least significant bit of each byte.
struct VP8LBitWriter {
    private(set) var bytes: [UInt8] = []
    private var accumulator: UInt64 = 0
    private var used = 0

    init(capacity: Int = 1 << 16) {
        bytes.reserveCapacity(capacity)
    }

    @inline(__always)
    mutating func write(_ value: Int, _ count: Int) {
        guard count > 0 else { return }
        accumulator |= (UInt64(truncatingIfNeeded: value) & ((1 << UInt64(count)) - 1)) << UInt64(used)
        used += count
        while used >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator >>= 8
            used -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if used > 0 {
            bytes.append(UInt8(truncatingIfNeeded: accumulator))
            accumulator = 0
            used = 0
        }
        return bytes
    }
}

/// A canonical prefix (Huffman) code over one alphabet, as written by VP8L.
struct PrefixCode {
    /// Code length per symbol (0 = unused).
    var lengths: [UInt8]
    /// Bit-reversed codes, ready for an LSB-first writer.
    var codes: [UInt16]
    /// A code with a single used symbol takes zero bits per symbol.
    var isZeroBit: Bool

    @inline(__always)
    func write(_ symbol: Int, to writer: inout VP8LBitWriter) {
        if isZeroBit { return }
        writer.write(Int(codes[symbol]), Int(lengths[symbol]))
    }

    /// Builds a length-limited Huffman code from symbol counts.
    init(counts: [Int], maxLength: Int = 15) {
        let n = counts.count
        var lengths = [UInt8](repeating: 0, count: n)
        let used = counts.indices.filter { counts[$0] > 0 }
        if used.count <= 1 {
            // Zero or one symbol: no bits needed. Keep a length of 1 on the symbol so the
            // header can describe it.
            if let only = used.first { lengths[only] = 1 }
            self.lengths = lengths
            self.codes = [UInt16](repeating: 0, count: n)
            self.isZeroBit = true
            return
        }
        var weights = counts
        var floor = 1
        while true {
            let built = PrefixCode.huffmanLengths(weights)
            if (built.max() ?? 0) <= UInt8(maxLength) {
                lengths = built
                break
            }
            // Too deep: flatten the distribution and try again.
            floor *= 2
            for i in used { weights[i] = max(counts[i], floor) }
        }
        self.lengths = lengths
        self.codes = PrefixCode.canonicalCodes(lengths)
        self.isZeroBit = false
    }

    static func huffmanLengths(_ weights: [Int]) -> [UInt8] {
        let n = weights.count
        // Nodes 0..<n are leaves; internal nodes are appended.
        var parent = [Int](repeating: -1, count: 2 * n)
        var heap = MinHeap()
        for i in 0..<n where weights[i] > 0 {
            heap.push(weight: weights[i], node: i)
        }
        var next = n
        while heap.count > 1 {
            let a = heap.pop()
            let b = heap.pop()
            parent[a.node] = next
            parent[b.node] = next
            heap.push(weight: a.weight + b.weight, node: next)
            next += 1
        }
        var lengths = [UInt8](repeating: 0, count: n)
        for i in 0..<n where weights[i] > 0 {
            var depth = 0
            var node = i
            while parent[node] >= 0 {
                node = parent[node]
                depth += 1
            }
            lengths[i] = UInt8(min(depth, 255))
        }
        return lengths
    }

    /// Canonical code assignment (shorter codes first, ties broken by symbol), bit-reversed.
    static func canonicalCodes(_ lengths: [UInt8]) -> [UInt16] {
        let maxLen = Int(lengths.max() ?? 0)
        var blCount = [Int](repeating: 0, count: maxLen + 1)
        for l in lengths where l > 0 { blCount[Int(l)] += 1 }
        var nextCode = [Int](repeating: 0, count: maxLen + 2)
        var code = 0
        if maxLen >= 1 {
            for bits in 1...maxLen {
                code = (code + blCount[bits - 1]) << 1
                nextCode[bits] = code
            }
        }
        var codes = [UInt16](repeating: 0, count: lengths.count)
        for (symbol, l) in lengths.enumerated() where l > 0 {
            let len = Int(l)
            let c = nextCode[len]
            nextCode[len] += 1
            var reversed = 0
            for b in 0..<len where c & (1 << b) != 0 {
                reversed |= 1 << (len - 1 - b)
            }
            codes[symbol] = UInt16(reversed)
        }
        return codes
    }
}

/// Binary min-heap keyed by weight, ties broken by node index for deterministic output.
private struct MinHeap {
    private var items: [(weight: Int, node: Int)] = []
    var count: Int { items.count }

    mutating func push(weight: Int, node: Int) {
        items.append((weight, node))
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if less(items[i], items[p]) {
                items.swapAt(i, p)
                i = p
            } else {
                break
            }
        }
    }

    mutating func pop() -> (weight: Int, node: Int) {
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && less(items[l], items[m]) { m = l }
                if r < items.count && less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }

    private func less(_ a: (weight: Int, node: Int), _ b: (weight: Int, node: Int)) -> Bool {
        a.weight != b.weight ? a.weight < b.weight : a.node < b.node
    }
}
