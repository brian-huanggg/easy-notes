import Foundation
import libzstd

/// zstd 解壓（Anki 2.1.50 起的 `.apkg`：collection、media 清單與每個媒體檔）
enum Zstd {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func isCompressed(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x28, 0xB5, 0x2F, 0xFD])
    }

    /// 串流解壓（frame 不一定記錄原始大小）；輸出超過 `limit` 時丟出錯誤（不可信任的輸入）
    static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw Failure(description: "zstd: out of memory") }
        defer { ZSTD_freeDStream(stream) }
        ZSTD_initDStream(stream)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var bufferFull = false
            repeat {
                let produced = try buffer.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
                    var out = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                    let result = ZSTD_decompressStream(stream, &out, &input)
                    if ZSTD_isError(result) != 0 {
                        throw Failure(description: "zstd: " + String(cString: ZSTD_getErrorName(result)))
                    }
                    return out.pos
                }
                output.append(buffer, count: produced)
                guard output.count <= limit else { throw Failure(description: "zstd: output too large") }
                bufferFull = produced == buffer.count
            } while input.pos < input.size || bufferFull
        }
        return output
    }
}
