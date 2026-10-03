import EasyNotesCore
import Foundation

extension SheetDocument {
    /// 以記錄為單位的 diff3；衝突區塊再逐記錄、逐儲存格三方合併。
    /// 兩邊在同一位置各自新增列時兩邊都保留（本地在前）。結果依本地的風格還原 BOM 與檔尾換行。
    /// 任一邊不可編輯（非 UTF-8）時只接受相同內容。
    static func merge(base: Data, local: Data, remote: Data, delimiter: UInt8) -> Data? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        let o = SheetDocument(data: base, delimiter: delimiter)
        let l = SheetDocument(data: local, delimiter: delimiter)
        let r = SheetDocument(data: remote, delimiter: delimiter)
        guard o.isEditable, l.isEditable, r.isEditable else { return nil }

        let merged = Diff3.merge(base: o.units(), local: l.units(), remote: r.units()) { ob, lb, rb in
            if ob.isEmpty { return Array(lb) + Array(rb) }
            guard ob.count == lb.count, lb.count == rb.count else { return nil }
            var out: [Data] = []
            for (x, (y, z)) in zip(ob, zip(lb, rb)) {
                guard let record = mergeRecord(base: x, local: y, remote: z, style: l.style) else { return nil }
                out.append(record)
            }
            return out
        }
        guard let merged else { return nil }

        var out = Data(merged.joined())
        if !l.style.trailingNewline, out.last == ASCII.lf {
            out.removeLast(out.suffix(2) == Data([ASCII.cr, ASCII.lf]) ? 2 : 1)
        }
        return l.style.hasBOM ? Data(bom) + out : out
    }

    /// 合併單位：每筆記錄的原始位元組加換行；檔尾沒有換行的最後一筆補上換行，
    /// 否則「在檔尾附加列」會讓原本的最後一筆也變動
    func units() -> [Data] {
        records.enumerated().map { i, record in
            let terminator = i == records.count - 1 && record.terminator.isEmpty ? style.lineEnding.bytes : record.terminator
            return (record.raw ?? Self.encode(record.fields, style: style)) + terminator
        }
    }

    /// 同一筆記錄兩邊都改了：欄數相同時逐儲存格合併，同一格改成不同值則衝突
    static func mergeRecord(base: Data, local: Data, remote: Data, style: Style) -> Data? {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        func parse(_ unit: Data) -> (fields: [String], terminator: Data)? {
            let bytes = [UInt8](unit)
            let scanned = scan(bytes, delimiter: style.delimiter)
            guard scanned.count == 1, let record = scanned.first else { return nil }
            return (record.fields.map { decode($0, .utf8) }, Data(bytes[record.content.upperBound...]))
        }
        guard let o = parse(base), let l = parse(local), let r = parse(remote),
              o.fields.count == l.fields.count, l.fields.count == r.fields.count else { return nil }
        var fields: [String] = []
        for (x, (y, z)) in zip(o.fields, zip(l.fields, r.fields)) {
            if y == x || y == z {
                fields.append(z == x ? y : z)
            } else if z == x {
                fields.append(y)
            } else {
                return nil
            }
        }
        return encode(fields, style: style) + l.terminator
    }
}
