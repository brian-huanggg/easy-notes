import Foundation

/// Fractional index（Excalidraw 的 `index` 欄位用的是 rocicorp/fractional-indexing，base62）。
/// 在兩個 key 之間永遠能產生新的 key，所以插入元素不必改動其他元素，合併時也能依 key 排序。
enum FractionalIndex {
    struct Invalid: Error { let reason: String }

    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let smallestInteger = "A" + String(repeating: "0", count: 26)

    /// 逐 byte 比較（與 JS 的字串比較一致）；key 都是 ASCII
    static func less(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    static func isValid(_ key: String) -> Bool {
        (try? validate(key)) != nil
    }

    /// `a` 與 `b` 之間的 key；`a` 為 nil = 最前面，`b` 為 nil = 最後面
    static func between(_ a: String?, _ b: String?) throws -> String {
        if let a { try validate(a) }
        if let b { try validate(b) }
        if let a, let b, !less(a, b) { throw Invalid(reason: "\(a) >= \(b)") }

        guard let a else {
            guard let b else { return "a" + String(digits[0]) }
            let ib = try integerPart(b), fb = String(b.dropFirst(ib.count))
            if ib == smallestInteger { return ib + (try midpoint("", fb)) }
            if less(ib, b) { return ib }
            guard let res = decrement(ib) else { throw Invalid(reason: "cannot decrement \(ib)") }
            return res
        }
        guard let b else {
            let ia = try integerPart(a), fa = String(a.dropFirst(ia.count))
            if let i = increment(ia) { return i }
            return ia + (try midpoint(fa, nil))
        }
        let ia = try integerPart(a), fa = String(a.dropFirst(ia.count))
        let ib = try integerPart(b), fb = String(b.dropFirst(ib.count))
        if ia == ib { return ia + (try midpoint(fa, fb)) }
        guard let i = increment(ia) else { throw Invalid(reason: "cannot increment \(ia)") }
        if less(i, b) { return i }
        return ia + (try midpoint(fa, nil))
    }

    /// `a` 與 `b` 之間的 `n` 個 key（遞增）
    static func between(_ a: String?, _ b: String?, count n: Int) throws -> [String] {
        if n <= 0 { return [] }
        if n == 1 { return [try between(a, b)] }
        if b == nil {
            var c = try between(a, b)
            var result = [c]
            for _ in 0..<(n - 1) { c = try between(c, b); result.append(c) }
            return result
        }
        if a == nil {
            var c = try between(a, b)
            var result = [c]
            for _ in 0..<(n - 1) { c = try between(a, c); result.append(c) }
            return result.reversed()
        }
        let mid = n / 2
        let c = try between(a, b)
        return try between(a, c, count: mid) + [c] + between(c, b, count: n - mid - 1)
    }

    // MARK: 內部

    private static func midpoint(_ a: String, _ b: String?) throws -> String {
        let a = Array(a), b = b.map(Array.init)
        return String(try midpoint(a[...], b?[...]))
    }

    private static func midpoint(_ a: ArraySlice<Character>, _ b: ArraySlice<Character>?) throws -> [Character] {
        let zero = digits[0]
        if let b, !less(String(a), String(b)) { throw Invalid(reason: "\(String(a)) >= \(String(b))") }
        if a.last == zero || b?.last == zero { throw Invalid(reason: "trailing zero") }

        if let b {
            var n = 0
            while (a.count > n ? a[a.startIndex + n] : zero) == (b.count > n ? b[b.startIndex + n] : nil) { n += 1 }
            if n > 0 {
                return Array(b.prefix(n)) + (try midpoint(a.dropFirst(min(n, a.count)), b.dropFirst(n)))
            }
        }
        let digitA = a.first.flatMap { digits.firstIndex(of: $0) } ?? 0
        let digitB = b?.first.flatMap { digits.firstIndex(of: $0) } ?? digits.count
        if digitB - digitA > 1 {
            // JS 的 Math.round(0.5 * x) 對 .5 進位
            return [digits[(digitA + digitB + 1) / 2]]
        }
        if let b, b.count > 1 { return [b[b.startIndex]] }
        return [digits[digitA]] + (try midpoint(a.dropFirst(), nil))
    }

    private static func integerLength(_ head: Character) throws -> Int {
        guard let v = head.asciiValue else { throw Invalid(reason: "invalid head \(head)") }
        switch head {
        case "a"..."z": return Int(v) - Int(UInt8(ascii: "a")) + 2
        case "A"..."Z": return Int(UInt8(ascii: "Z")) - Int(v) + 2
        default: throw Invalid(reason: "invalid head \(head)")
        }
    }

    private static func integerPart(_ key: String) throws -> String {
        guard let head = key.first else { throw Invalid(reason: "empty key") }
        let length = try integerLength(head)
        guard length <= key.count else { throw Invalid(reason: "invalid integer part of \(key)") }
        return String(key.prefix(length))
    }

    private static func validate(_ key: String) throws {
        if key == smallestInteger { throw Invalid(reason: "invalid key \(key)") }
        let i = try integerPart(key)
        if key.dropFirst(i.count).last == digits[0] { throw Invalid(reason: "invalid key \(key)") }
        if !key.allSatisfy({ digits.contains($0) }) { throw Invalid(reason: "invalid digit in \(key)") }
    }

    private static func increment(_ x: String) -> String? {
        var chars = Array(x)
        let head = chars.removeFirst()
        var carry = true
        var i = chars.count - 1
        while carry && i >= 0 {
            let d = digits.firstIndex(of: chars[i])! + 1
            if d == digits.count {
                chars[i] = digits[0]
            } else {
                chars[i] = digits[d]
                carry = false
            }
            i -= 1
        }
        if carry {
            if head == "Z" { return "a" + String(digits[0]) }
            if head == "z" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! + 1))
            if h > "a" { chars.append(digits[0]) } else { chars.removeLast() }
            return String(h) + String(chars)
        }
        return String(head) + String(chars)
    }

    private static func decrement(_ x: String) -> String? {
        var chars = Array(x)
        let head = chars.removeFirst()
        var borrow = true
        var i = chars.count - 1
        while borrow && i >= 0 {
            let d = digits.firstIndex(of: chars[i])! - 1
            if d == -1 {
                chars[i] = digits[digits.count - 1]
            } else {
                chars[i] = digits[d]
                borrow = false
            }
            i -= 1
        }
        if borrow {
            if head == "a" { return "Z" + String(digits[digits.count - 1]) }
            if head == "A" { return nil }
            let h = Character(UnicodeScalar(head.asciiValue! - 1))
            if h < "Z" { chars.append(digits[digits.count - 1]) } else { chars.removeLast() }
            return String(h) + String(chars)
        }
        return String(head) + String(chars)
    }
}
