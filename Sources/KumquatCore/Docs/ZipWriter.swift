import Compression
import Foundation

/// Minimal ZIP archive writer (stored or deflated entries), enough for DOCX packages.
public struct ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    public mutating func add(_ name: String, data: Data, compress: Bool = true) {
        let crc = CRC32.checksum(data)
        var payload = data
        var method: UInt16 = 0
        if compress, data.count > 64, let deflated = Self.deflate(data), deflated.count < data.count {
            payload = deflated
            method = 8
        }
        let nameBytes = Array(name.utf8)
        let entry = Entry(name: nameBytes, crc: crc, compressedSize: UInt32(payload.count),
                          uncompressedSize: UInt32(data.count), method: method, offset: UInt32(output.count))
        output.appendLE32(0x0403_4b50)
        output.appendLE16(20)
        output.appendLE16(nameBytes.allSatisfy { $0 < 0x80 } ? 0 : 0x0800)
        output.appendLE16(method)
        output.appendLE16(dosTime)
        output.appendLE16(dosDate)
        output.appendLE32(crc)
        output.appendLE32(entry.compressedSize)
        output.appendLE32(entry.uncompressedSize)
        output.appendLE16(UInt16(nameBytes.count))
        output.appendLE16(0)
        output.append(contentsOf: nameBytes)
        output.append(payload)
        entries.append(entry)
    }

    public mutating func add(_ name: String, text: String) {
        add(name, data: Data(text.utf8))
    }

    public mutating func finish() -> Data {
        let directoryOffset = UInt32(output.count)
        for e in entries {
            output.appendLE32(0x0201_4b50)
            output.appendLE16(20)
            output.appendLE16(20)
            output.appendLE16(e.name.allSatisfy { $0 < 0x80 } ? 0 : 0x0800)
            output.appendLE16(e.method)
            output.appendLE16(dosTime)
            output.appendLE16(dosDate)
            output.appendLE32(e.crc)
            output.appendLE32(e.compressedSize)
            output.appendLE32(e.uncompressedSize)
            output.appendLE16(UInt16(e.name.count))
            output.appendLE16(0) // extra
            output.appendLE16(0) // comment
            output.appendLE16(0) // disk
            output.appendLE16(0) // internal attributes
            output.appendLE32(0) // external attributes
            output.appendLE32(e.offset)
            output.append(contentsOf: e.name)
        }
        let directorySize = UInt32(output.count) - directoryOffset
        output.appendLE32(0x0605_4b50)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(UInt16(entries.count))
        output.appendLE16(UInt16(entries.count))
        output.appendLE32(directorySize)
        output.appendLE32(directoryOffset)
        output.appendLE16(0)
        return output
    }

    /// Raw DEFLATE (RFC 1951) via the Compression framework.
    static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data, initial: UInt32 = 0) -> UInt32 {
        var crc = ~initial
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
        }
        return ~crc
    }
}

extension Data {
    mutating func appendLE16(_ v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8(v >> 8))
    }

    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8(v >> 24))
    }

    mutating func appendBE32(_ v: UInt32) {
        append(UInt8(v >> 24))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
}
