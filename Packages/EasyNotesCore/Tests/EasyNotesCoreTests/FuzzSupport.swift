import Foundation

/// 決定性的突變式模糊測試工具：固定種子，失敗時可重現（崩潰會讓整個測試程序結束）。
/// 每個套件各放一份（測試 target 之間不共用）；修改時一起改。
struct FuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fuzz {
    /// 會讓解析器出事的常見片段
    static let tokens: [[UInt8]] = [
        [0], [13, 10], [13], [34], [34, 34], [44], [9], [10, 10, 10], [0xEF, 0xBB, 0xBF], [0xFF, 0xFE], [0xC0, 0x80], [0xED, 0xA0, 0x80],
        Array("[[".utf8), Array("]]".utf8), Array("---\n".utf8), Array("```".utf8), Array("{".utf8), Array("}".utf8), Array("[".utf8),
        Array("1e999".utf8), Array("-1e999".utf8), Array("NaN".utf8), Array("\\u0000".utf8), Array("\\ud800".utf8), Array("null".utf8),
        Array("![[".utf8), Array("<!--".utf8), Array("\u{202E}".utf8), Array("#".utf8), Array("^".utf8), Array("::".utf8), Array("{{c1::".utf8),
    ]

    static func mutate(_ seed: Data, _ rng: inout FuzzRNG) -> Data {
        var bytes = [UInt8](seed)
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0 where !bytes.isEmpty: bytes[Int.random(in: 0..<bytes.count, using: &rng)] ^= UInt8.random(in: 1...255, using: &rng)
            case 1 where !bytes.isEmpty:
                let a = Int.random(in: 0..<bytes.count, using: &rng), b = Int.random(in: a...bytes.count, using: &rng)
                bytes.removeSubrange(a..<b)
            case 2 where !bytes.isEmpty:
                let a = Int.random(in: 0..<bytes.count, using: &rng), b = Int.random(in: a...bytes.count, using: &rng)
                bytes.insert(contentsOf: bytes[a..<b], at: Int.random(in: 0...bytes.count, using: &rng))
            case 3: bytes.insert(contentsOf: (0..<Int.random(in: 1...16, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) },
                                 at: Int.random(in: 0...bytes.count, using: &rng))
            case 4 where !bytes.isEmpty: bytes.removeSubrange(Int.random(in: 0..<bytes.count, using: &rng)...)
            default: bytes.insert(contentsOf: tokens.randomElement(using: &rng)!, at: Int.random(in: 0...bytes.count, using: &rng))
            }
        }
        return Data(bytes)
    }

    /// 對每個種子跑 `rounds` 次突變，另外餵純隨機資料；每次執行超過 `limit` 秒就視為卡死
    static func run(seeds: [Data], rounds: Int = 400, limit: Double = 3, seed: UInt64 = 1,
                    _ body: (Data) -> Void) -> [String] {
        var rng = FuzzRNG(seed: seed)
        var slow: [String] = []
        var inputs = seeds
        for s in seeds { for _ in 0..<rounds { inputs.append(mutate(s, &rng)) } }
        for _ in 0..<rounds { inputs.append(Data((0..<Int.random(in: 0...256, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })) }
        for input in inputs {
            let start = ContinuousClock.now
            body(input)
            let seconds = Double((ContinuousClock.now - start).components.seconds)
            if seconds > limit { slow.append("\(seconds)s: \(input.prefix(80).base64EncodedString())") }
        }
        return slow
    }
}
