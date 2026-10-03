import Foundation

/// 以行為單位的三方合併（diff3）。不認識檔案類型，只看位元組：
/// 行尾符號（LF / CRLF）跟著行走，檔尾沒有換行的最後一行也是一行，所以不會改寫使用者的格式。
/// Markdown 與 CSV 這類以行為單位的格式在 `DocumentKind.merge` 中呼叫它。
public enum Diff3 {
    /// 非重疊的修改自動合併；兩邊改了同一段且結果不同時回傳 nil（由同步層產生衝突副本）
    public static func merge(base: Data, local: Data, remote: Data) -> Data? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        let merged = merge(base: lines(base), local: lines(local), remote: lines(remote))
        return merged.map { Data($0.joined()) }
    }

    /// 經典 diff3：以「base 中兩邊都沒動的行」為同步點，切出不穩定區塊逐一判斷。
    /// 兩邊改了同一段且結果不同時交給 `resolve`（base、local、remote 的該段）；它回傳 nil 代表衝突。
    /// 外掛用它在自己的單位內做更細的合併（例如 Sheets 逐儲存格），Core 仍不認識檔案類型。
    public static func merge<Line: Hashable>(
        base: [Line], local: [Line], remote: [Line],
        resolve: (_ base: ArraySlice<Line>, _ local: ArraySlice<Line>, _ remote: ArraySlice<Line>) -> [Line]? = { _, _, _ in nil }
    ) -> [Line]? {
        let toLocal = matching(from: base, to: local)
        let toRemote = matching(from: base, to: remote)
        var result: [Line] = []
        var i = 0, a = 0, b = 0
        while i < base.count || a < local.count || b < remote.count {
            if i < base.count, toLocal[i] == a, toRemote[i] == b {
                result.append(base[i])
                i += 1; a += 1; b += 1
                continue
            }
            // 下一個兩邊都保留的 base 行；沒有就延伸到結尾
            var j = i
            while j < base.count, toLocal[j] == nil || toRemote[j] == nil { j += 1 }
            let aEnd = j < base.count ? toLocal[j]! : local.count
            let bEnd = j < base.count ? toRemote[j]! : remote.count
            let o = base[i..<j], l = local[a..<aEnd], r = remote[b..<bEnd]
            if l.elementsEqual(o) {
                result += r
            } else if r.elementsEqual(o) || l.elementsEqual(r) {
                result += l
            } else if let resolved = resolve(o, l, r) {
                result += resolved
            } else {
                return nil
            }
            i = j; a = aEnd; b = bEnd
        }
        return result
    }

    /// base 每一行對應到另一邊的行號（LCS，Myers diff）；被刪除或改掉的行為 nil
    static func matching<Line: Hashable>(from base: [Line], to other: [Line]) -> [Int?] {
        let diff = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: base.count)
        var k = 0
        for i in base.indices where !removed.contains(i) {
            while inserted.contains(k) { k += 1 }
            result[i] = k
            k += 1
        }
        return result
    }

    /// 依 `\n` 切行並保留行尾，`lines(x).joined() == x`
    static func lines(_ data: Data) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            result.append(data[start...i])
            start = i + 1
        }
        if start < data.endIndex { result.append(data[start...]) }
        return result
    }
}
