import Compression
import Foundation

/// 唯讀的 zip（`.apkg`）：讀 central directory，項目只在需要時讀出並解壓。
/// 只支援 stored 與 deflate（`COMPRESSION_ZLIB` 即 raw deflate），含 zip64；不驗 CRC
struct ZipArchive {
    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let url: URL
    let entries: [String: Entry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        // End of central directory：在最後 64 KB + 22 bytes 內由後往前找
        let tailSize = min(fileSize, 65_557)
        let tail = try Self.read(handle, at: fileSize - tailSize, count: Int(tailSize))
        guard let eocd = Self.lastIndex(of: 0x0605_4B50, in: tail) else { throw Failure(description: "not a zip file") }
        var count = UInt64(tail.u16(eocd + 10))
        var directorySize = UInt64(tail.u32(eocd + 12))
        var directoryOffset = UInt64(tail.u32(eocd + 16))
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF, eocd >= 20, tail.u32(eocd - 20) == 0x0706_4B50 {
            let zip64 = try Self.read(handle, at: tail.u64(eocd - 20 + 8), count: 56)
            guard zip64.u32(0) == 0x0606_4B50 else { throw Failure(description: "bad zip64 record") }
            count = zip64.u64(32)
            directorySize = zip64.u64(40)
            directoryOffset = zip64.u64(48)
        }
        guard directoryOffset + directorySize <= fileSize, directorySize < 64 << 20 else {
            throw Failure(description: "bad central directory")
        }
        let directory = try Self.read(handle, at: directoryOffset, count: Int(directorySize))

        var entries: [String: Entry] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= directory.count, directory.u32(p) == 0x0201_4B50 else { break }
            let nameLength = Int(directory.u16(p + 28))
            let extraLength = Int(directory.u16(p + 30))
            let commentLength = Int(directory.u16(p + 32))
            guard p + 46 + nameLength + extraLength <= directory.count else { break }
            var compressed = UInt64(directory.u32(p + 20))
            var size = UInt64(directory.u32(p + 24))
            var offset = UInt64(directory.u32(p + 42))
            // zip64 extra（0x0001）：依序是原本為 0xFFFFFFFF 的 size、compressed、offset
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = directory.u16(e)
                let length = Int(directory.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF, q + 8 <= e + 4 + length { size = directory.u64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= e + 4 + length { compressed = directory.u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= e + 4 + length { offset = directory.u64(q) }
                }
                e += 4 + length
            }
            let nameData = directory.subdata(in: (p + 46)..<(p + 46 + nameLength))
            let name = String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: directory.u16(p + 10), compressedSize: compressed, size: size,
                                  localHeaderOffset: offset)
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// 讀出並解壓一個項目；解壓後超過 `limit` 時丟出錯誤（不可信任的輸入）
    func data(_ name: String, limit: Int) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.size <= UInt64(limit), entry.compressedSize <= UInt64(limit) else {
            throw Failure(description: "\(name) is too large")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try Self.read(handle, at: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x0403_4B50 else { throw Failure(description: "bad local header") }
        let start = entry.localHeaderOffset + 30 + UInt64(header.u16(26)) + UInt64(header.u16(28))
        let raw = try Self.read(handle, at: start, count: Int(entry.compressedSize))
        switch entry.method {
        case 0:
            return raw
        case 8:
            if entry.size == 0 { return Data() }
            var output = Data(count: Int(entry.size))
            let written = output.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(entry.size),
                                              src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == Int(entry.size) else { throw Failure(description: "\(name): inflate failed") }
            return output
        default:
            throw Failure(description: "\(name): unsupported compression \(entry.method)")
        }
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Failure(description: "unexpected end of file") }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        while i >= 0 {
            if data.u32(i) == signature { return i }
            i -= 1
        }
        return nil
    }
}

extension Data {
    /// little-endian；`i` 從 0 起算（相對於 `startIndex`）
    func u16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
    }

    func u64(_ i: Int) -> UInt64 {
        UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
    }
}
