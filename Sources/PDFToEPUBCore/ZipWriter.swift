import Foundation
#if canImport(Compression)
import Compression
#endif

/// A small ZIP archive writer, enough for EPUB containers.
///
/// EPUB needs the `mimetype` entry first and uncompressed, which is why this
/// lets each entry choose whether it is compressed.
struct ZipWriter {
    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var offset: UInt32
    }

    private(set) var data = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year: Int = min(2107, max(1980, c.year ?? 1980)) - 1980
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = (c.second ?? 0) / 2
        dosDate = UInt16((year << 9) | (month << 5) | day)
        dosTime = UInt16((hour << 11) | (minute << 5) | second)
    }

    mutating func add(_ name: String, _ content: Data, compress: Bool = true) {
        let crc = CRC32.checksum(content)
        var payload = content
        var method: UInt16 = 0
        if compress, let deflated = Self.deflate(content), deflated.count < content.count {
            payload = deflated
            method = 8
        }
        let nameBytes = Array(name.utf8)
        let entry = Entry(name: nameBytes, crc: crc, compressedSize: UInt32(payload.count),
                          uncompressedSize: UInt32(content.count), method: method, offset: UInt32(data.count))
        data.append(le32: 0x0403_4b50)
        data.append(le16: 20)                 // version needed
        data.append(le16: 0x0800)             // UTF-8 names
        data.append(le16: method)
        data.append(le16: dosTime)
        data.append(le16: dosDate)
        data.append(le32: crc)
        data.append(le32: entry.compressedSize)
        data.append(le32: entry.uncompressedSize)
        data.append(le16: UInt16(nameBytes.count))
        data.append(le16: 0)                  // extra field length
        data.append(contentsOf: nameBytes)
        data.append(payload)
        entries.append(entry)
    }

    mutating func add(_ name: String, _ text: String, compress: Bool = true) {
        add(name, Data(text.utf8), compress: compress)
    }

    func finalized() -> Data {
        var out = data
        let directoryStart = UInt32(out.count)
        for entry in entries {
            out.append(le32: 0x0201_4b50)
            out.append(le16: 20)              // version made by
            out.append(le16: 20)              // version needed
            out.append(le16: 0x0800)
            out.append(le16: entry.method)
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: entry.crc)
            out.append(le32: entry.compressedSize)
            out.append(le32: entry.uncompressedSize)
            out.append(le16: UInt16(entry.name.count))
            out.append(le16: 0)               // extra
            out.append(le16: 0)               // comment
            out.append(le16: 0)               // disk number
            out.append(le16: 0)               // internal attributes
            out.append(le32: 0)               // external attributes
            out.append(le32: entry.offset)
            out.append(contentsOf: entry.name)
        }
        let directorySize = UInt32(out.count) - directoryStart
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: directorySize)
        out.append(le32: directoryStart)
        out.append(le16: 0)
        return out
    }

    /// Raw DEFLATE (RFC 1951), which is what ZIP method 8 stores.
    static func deflate(_ input: Data) -> Data? {
        #if canImport(Compression)
        guard !input.isEmpty else { return nil }
        let capacity = input.count + input.count / 10 + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
        #else
        return nil
        #endif
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
