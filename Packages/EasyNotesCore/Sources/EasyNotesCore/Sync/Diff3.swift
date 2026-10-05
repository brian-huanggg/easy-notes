import Foundation

/// Line-based three-way merge (diff3). Knows no file types, only bytes:
/// line endings (LF / CRLF) travel with their lines, and a final line with no trailing newline is also a line, so the user's format is never rewritten.
/// Line-based formats such as Markdown and CSV call it from `DocumentKind.merge`.
public enum Diff3 {
    /// Non-overlapping edits merge automatically; when both sides changed the same hunk with different results it returns nil (the sync layer creates a conflict copy)
    public static func merge(base: Data, local: Data, remote: Data) -> Data? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        let merged = merge(base: lines(base), local: lines(local), remote: lines(remote))
        return merged.map { Data($0.joined()) }
    }

    /// Classic diff3: uses "lines of base that neither side touched" as sync points and cuts out unstable hunks to judge one by one.
    /// When both sides changed the same hunk with different results it hands over to `resolve` (that hunk's base, local, remote); nil means conflict.
    /// Plugins use it to merge more finely within their own unit (for example Sheets per cell); Core still knows no file types.
    public static func merge<Line: Hashable>(
        base: [Line], local: [Line], remote: [Line],
        resolve: (_ base: ArraySlice<Line>, _ local: ArraySlice<Line>, _ remote: ArraySlice<Line>) -> [Line]? = { _, _, _ in nil }
    ) -> [Line]? {
        // The diff of pathological input (huge files where both sides rewrote almost everything) is quadratic and would hang sync: above the cap it counts as a conflict and the sync layer leaves a conflict copy
        guard diffCost(base, local) <= maxDiffCost, diffCost(base, remote) <= maxDiffCost else { return nil }
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
            // The next base line both sides kept; extend to the end if none
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

    /// The cost of Myers diff is about (lines on both sides) × (differing lines); above this value it counts as a conflict.
    /// About 400 million operations: under 1 s in release, over ten seconds in debug. Ordinary edits (small changes, scattered changes, pasting a few thousand lines) are far below it
    static let maxDiffCost = 400_000_000

    /// After removing the identical prefix and suffix, estimates the diff distance from "the number of lines that do not match on either side" and returns the estimated cost.
    /// Pure insertions and deletions (the middle of one side is empty) cost 0; only huge files rewritten almost entirely exceed the cap
    static func diffCost<Line: Hashable>(_ a: [Line], _ b: [Line]) -> Int {
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        let middleA = a[head..<(a.count - tail)], middleB = b[head..<(b.count - tail)]
        if middleA.isEmpty || middleB.isEmpty { return 0 }
        var remaining: [Line: Int] = [:]
        for line in middleA { remaining[line, default: 0] += 1 }
        var unmatchedB = 0
        for line in middleB {
            if let n = remaining[line], n > 0 { remaining[line] = n - 1 } else { unmatchedB += 1 }
        }
        let distance = remaining.values.reduce(0, +) + unmatchedB
        let (cost, overflow) = (middleA.count + middleB.count).multipliedReportingOverflow(by: distance)
        return overflow ? Int.max : cost
    }

    /// For each line of base, the line number on the other side (LCS, Myers diff); nil for deleted or changed lines
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

    /// Splits lines on `\n` and keeps line endings, so `lines(x).joined() == x`
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
