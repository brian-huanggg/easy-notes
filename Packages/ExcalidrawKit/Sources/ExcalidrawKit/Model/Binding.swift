import CoreGraphics
import Foundation

/// 綁定用的幾何。形狀可旋轉：先轉回未旋轉的座標計算，結果再轉回去。
public enum Geometry {
    public static func rotate(_ p: CGPoint, around c: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return p }
        let s = sin(angle), co = cos(angle)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }

    /// 形狀上 `ratio`（0...1）位置的絕對座標
    public static func point(in shape: Element, ratio: CGPoint) -> CGPoint {
        rotate(CGPoint(x: shape.x + ratio.x * shape.width, y: shape.y + ratio.y * shape.height),
               around: shape.center, by: shape.angle)
    }

    /// 連接點：上、右、下、左邊的中點（形狀上的比例）與各自的外法線（未旋轉）
    public static let sides: [(ratio: CGPoint, normal: CGPoint)] = [
        (CGPoint(x: 0.5, y: 0), CGPoint(x: 0, y: -1)),
        (CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 0)),
        (CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1)),
        (CGPoint(x: 0, y: 0.5), CGPoint(x: -1, y: 0)),
    ]

    /// `ratio` 是哪一個連接點（不是就回傳 nil）
    static func side(_ ratio: CGPoint) -> Int? {
        sides.firstIndex { abs($0.ratio.x - ratio.x) < 1e-3 && abs($0.ratio.y - ratio.y) < 1e-3 }
    }

    /// 綁在連接點上的端點：該邊中點沿外法線外移 `gap`
    public static func sideEndpoint(_ shape: Element, side: Int, gap: Double) -> CGPoint {
        let (ratio, n) = sides[side]
        let local = CGPoint(x: shape.x + ratio.x * shape.width + n.x * gap,
                            y: shape.y + ratio.y * shape.height + n.y * gap)
        return rotate(local, around: shape.center, by: shape.angle)
    }

    /// 絕對座標 `p` 在形狀上的位置比例，夾在 0...1（形狀外的點投影到邊上）
    static func ratio(of p: CGPoint, in shape: Element) -> CGPoint {
        let local = rotate(p, around: shape.center, by: -shape.angle)
        let rx = shape.width > 0 ? (local.x - shape.x) / shape.width : 0.5
        let ry = shape.height > 0 ? (local.y - shape.y) / shape.height : 0.5
        return CGPoint(x: min(max(rx, 0), 1), y: min(max(ry, 0), 1))
    }

    /// 從 `origin`（形狀外）朝 `target` 的射線，進入「形狀輪廓向外擴 `gap`」的第一個交點，
    /// 所以交點到形狀的距離就是 `gap`（Excalidraw 的 binding gap）。起點在其內或沒有交點回傳 nil。
    static func entry(from origin: CGPoint, toward target: CGPoint, shape: Element, gap: Double = 0) -> CGPoint? {
        let c = shape.center
        let o = rotate(origin, around: c, by: -shape.angle)
        let t = rotate(target, around: c, by: -shape.angle)
        let d = CGPoint(x: t.x - o.x, y: t.y - o.y)
        guard d.x != 0 || d.y != 0 else { return nil }

        let s: Double?
        switch shape.type {
        case .ellipse: s = ellipseEntry(o, d, shape, gap)
        case .diamond: s = diamondEntry(o, d, shape, gap)
        default: s = boxEntry(o, d, shape.rect.insetBy(dx: -gap, dy: -gap))
        }
        guard let s else { return nil }
        return rotate(CGPoint(x: o.x + d.x * s, y: o.y + d.y * s), around: c, by: shape.angle)
    }

    private static func boxEntry(_ o: CGPoint, _ d: CGPoint, _ r: CGRect) -> Double? {
        var tMin = -Double.infinity, tMax = Double.infinity
        for (origin, dir, lo, hi) in [(o.x, d.x, r.minX, r.maxX), (o.y, d.y, r.minY, r.maxY)] {
            if dir == 0 {
                if origin < lo || origin > hi { return nil }
            } else {
                let a = (lo - origin) / dir, b = (hi - origin) / dir
                tMin = max(tMin, min(a, b))
                tMax = min(tMax, max(a, b))
            }
        }
        guard tMin <= tMax, tMax >= 0, tMin >= 0 else { return nil } // tMin < 0：起點在形狀內
        return tMin
    }

    private static func ellipseEntry(_ o: CGPoint, _ d: CGPoint, _ shape: Element, _ gap: Double) -> Double? {
        let a = shape.width / 2 + gap, b = shape.height / 2 + gap
        guard a > 0, b > 0 else { return nil }
        let c = shape.center
        let ox = (o.x - c.x) / a, oy = (o.y - c.y) / b, dx = d.x / a, dy = d.y / b
        let qa = dx * dx + dy * dy, qb = 2 * (ox * dx + oy * dy), qc = ox * ox + oy * oy - 1
        guard qc > 0 else { return nil }
        let disc = qb * qb - 4 * qa * qc
        guard disc >= 0 else { return nil }
        let s = (-qb - disc.squareRoot()) / (2 * qa)
        return s >= 0 ? s : nil
    }

    private static func diamondEntry(_ o: CGPoint, _ d: CGPoint, _ shape: Element, _ gap: Double) -> Double? {
        let c = shape.center
        var hw = shape.width / 2, hh = shape.height / 2
        guard hw > 0, hh > 0 else { return nil }
        // 菱形的邊向外平移 gap = 以中心等比例放大，使中心到邊的距離增加 gap
        let k = 1 + gap * (1 / (hw * hw) + 1 / (hh * hh)).squareRoot()
        hw *= k; hh *= k
        if abs(o.x - c.x) / hw + abs(o.y - c.y) / hh <= 1 { return nil }
        let v = [CGPoint(x: c.x, y: c.y - hh), CGPoint(x: c.x + hw, y: c.y),
                 CGPoint(x: c.x, y: c.y + hh), CGPoint(x: c.x - hw, y: c.y)]
        var best: Double?
        for i in 0..<4 {
            let p = v[i], e = CGPoint(x: v[(i + 1) % 4].x - p.x, y: v[(i + 1) % 4].y - p.y)
            let denom = d.x * e.y - d.y * e.x
            guard abs(denom) > 1e-12 else { continue }
            let s = ((p.x - o.x) * e.y - (p.y - o.y) * e.x) / denom
            let u = ((p.x - o.x) * d.y - (p.y - o.y) * d.x) / denom
            if s >= 0, u >= -1e-9, u <= 1 + 1e-9, best == nil || s < best! { best = s }
        }
        return best
    }
}

extension SceneEditor {
    // MARK: 建立與移除綁定

    /// 把箭頭的一端綁到形狀上，並把端點移到形狀輪廓外 `gap` 處。
    /// `fixedPoint`（形狀上的 0...1 位置）省略時取目前端點投影到形狀上的位置。
    @discardableResult
    mutating func bind(_ arrowID: String, _ end: ArrowEnd, to shapeID: String,
                       fixedPoint: CGPoint? = nil, gap: Double = 5) -> Bool {
        guard let arrow = self[arrowID], arrow.type == .arrow, !arrow.isDeleted,
              let shape = self[shapeID], !shape.isDeleted, shape.type.isBindableShape, shapeID != arrowID,
              let endpoint = end == .start ? arrow.absolutePoints.first : arrow.absolutePoints.last
        else { return false }

        if let old = arrow.binding(end)?.elementId, old != shapeID { removeBound(arrowID, from: old) }
        let ratio = fixedPoint ?? Geometry.ratio(of: endpoint, in: shape)
        let anchor = Geometry.point(in: shape, ratio: ratio)
        let origin = adjacentPoint(of: arrow, end)
        let binding = Binding(elementId: shapeID, focus: focus(anchor, from: origin, shape), gap: gap, fixedPoint: ratio)
        update(arrowID) { $0.setBinding(end, binding) }
        addBound(arrowID, type: "arrow", to: shapeID)
        rebindArrows(movedIDs: [shapeID], only: arrowID)
        return true
    }

    mutating func unbind(_ arrowID: String, _ end: ArrowEnd) {
        guard let arrow = self[arrowID], let target = arrow.binding(end)?.elementId else { return }
        update(arrowID) { $0.setBinding(end, nil) }
        // 另一端也綁在同一個形狀上時，boundElements 要保留
        let other: ArrowEnd = end == .start ? .end : .start
        if self[arrowID]?.binding(other)?.elementId != target { removeBound(arrowID, from: target) }
    }

    // MARK: 重算端點

    /// 綁在 `movedIDs` 上的箭頭重算被綁端點；只改需要變的點，沒變的箭頭不遞增 version。
    /// 彎曲箭頭只動端點，中間的點不變；elbow 箭頭的轉折路徑要重新走線，不在 4a 範圍，原樣保留。
    mutating func rebindArrows(movedIDs: Set<String>, only arrowID: String? = nil) {
        for arrow in elements where arrow.type == .arrow && !arrow.isDeleted && !arrow.isElbowArrow {
            if let arrowID, arrow.id != arrowID { continue }
            let start = arrow.binding(.start), end = arrow.binding(.end)
            let startMoved = start.map { movedIDs.contains($0.elementId) } ?? false
            let endMoved = end.map { movedIDs.contains($0.elementId) } ?? false
            guard startMoved || endMoved else { continue }

            var pts = arrow.absolutePoints
            guard pts.count >= 2 else { continue }
            let anchors = [start, end].map { b -> CGPoint? in
                guard let b, let shape = self[b.elementId], !shape.isDeleted else { return nil }
                return Geometry.point(in: shape, ratio: b.fixedPoint ?? CGPoint(x: 0.5, y: 0.5))
            }
            if startMoved, let b = start, let shape = self[b.elementId], let anchor = anchors[0] {
                let origin = pts.count > 2 ? pts[1] : (anchors[1] ?? pts[1])
                pts[0] = endpoint(shape: shape, binding: b, anchor: anchor, origin: origin)
            }
            if endMoved, let b = end, let shape = self[b.elementId], let anchor = anchors[1] {
                let n = pts.count
                let origin = n > 2 ? pts[n - 2] : (anchors[0] ?? pts[0])
                pts[n - 1] = endpoint(shape: shape, binding: b, anchor: anchor, origin: origin)
            }
            let old = arrow.absolutePoints
            let changed = zip(old, pts).contains { abs($0.x - $1.x) > 1e-6 || abs($0.y - $1.y) > 1e-6 }
            if changed { update(arrow.id) { $0.setAbsolutePoints(pts) } }
        }
    }

    /// 端點：綁在連接點上 → 該邊中點外移 `gap`（箭頭從背後過來也停在這一邊）；
    /// 其他 → 從 `origin` 朝 `anchor` 的射線，進入輪廓外 `gap` 處，射線沒碰到輪廓時直接用錨點
    private func endpoint(shape: Element, binding b: Binding, anchor: CGPoint, origin: CGPoint) -> CGPoint {
        if let ratio = b.fixedPoint, let side = Geometry.side(ratio) {
            return Geometry.sideEndpoint(shape, side: side, gap: b.gap)
        }
        return Geometry.entry(from: origin, toward: anchor, shape: shape, gap: b.gap) ?? anchor
    }

    /// 這一端旁邊的點：多點箭頭取相鄰的點，兩點箭頭取另一端
    private func adjacentPoint(of arrow: Element, _ end: ArrowEnd) -> CGPoint {
        let pts = arrow.absolutePoints
        guard pts.count >= 2 else { return pts.first ?? .zero }
        return end == .start ? pts[1] : pts[pts.count - 2]
    }

    /// 舊版 Excalidraw 用的 `focus`（-1...1）：錨點相對中心、垂直於箭頭方向的偏移。新版以 `fixedPoint` 為準。
    private func focus(_ anchor: CGPoint, from origin: CGPoint, _ shape: Element) -> Double {
        let dx = anchor.x - origin.x, dy = anchor.y - origin.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0 else { return 0 }
        let perp = CGPoint(x: -dy / len, y: dx / len)
        let c = shape.center
        let offset = (anchor.x - c.x) * perp.x + (anchor.y - c.y) * perp.y
        let half = abs(perp.x) * shape.width / 2 + abs(perp.y) * shape.height / 2
        return half > 0 ? min(max(offset / half, -1), 1) : 0
    }
}
