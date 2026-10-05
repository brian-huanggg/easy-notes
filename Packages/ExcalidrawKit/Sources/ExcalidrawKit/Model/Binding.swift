import CoreGraphics
import Foundation

/// Geometry for binding. Shapes can be rotated: compute in unrotated coordinates and rotate the result back.
public enum Geometry {
    public static func rotate(_ p: CGPoint, around c: CGPoint, by angle: Double) -> CGPoint {
        guard angle != 0 else { return p }
        let s = sin(angle), co = cos(angle)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }

    /// The absolute coordinates of the position at `ratio` (0...1) on the shape
    public static func point(in shape: Element, ratio: CGPoint) -> CGPoint {
        rotate(CGPoint(x: shape.x + ratio.x * shape.width, y: shape.y + ratio.y * shape.height),
               around: shape.center, by: shape.angle)
    }

    /// Connection points: the midpoints of the top, right, bottom and left edges (ratios on the shape) and their outward normals (unrotated)
    public static let sides: [(ratio: CGPoint, normal: CGPoint)] = [
        (CGPoint(x: 0.5, y: 0), CGPoint(x: 0, y: -1)),
        (CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 0)),
        (CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1)),
        (CGPoint(x: 0, y: 0.5), CGPoint(x: -1, y: 0)),
    ]

    /// Which connection point `ratio` is (nil if none)
    static func side(_ ratio: CGPoint) -> Int? {
        sides.firstIndex { abs($0.ratio.x - ratio.x) < 1e-3 && abs($0.ratio.y - ratio.y) < 1e-3 }
    }

    /// An endpoint bound to a connection point: that edge's midpoint moved outward by `gap` along the outward normal
    public static func sideEndpoint(_ shape: Element, side: Int, gap: Double) -> CGPoint {
        let (ratio, n) = sides[side]
        let local = CGPoint(x: shape.x + ratio.x * shape.width + n.x * gap,
                            y: shape.y + ratio.y * shape.height + n.y * gap)
        return rotate(local, around: shape.center, by: shape.angle)
    }

    /// The position ratio of absolute coordinates `p` on the shape, clamped to 0...1 (a point outside the shape is projected onto the edge)
    static func ratio(of p: CGPoint, in shape: Element) -> CGPoint {
        let local = rotate(p, around: shape.center, by: -shape.angle)
        let rx = shape.width > 0 ? (local.x - shape.x) / shape.width : 0.5
        let ry = shape.height > 0 ? (local.y - shape.y) / shape.height : 0.5
        return CGPoint(x: min(max(rx, 0), 1), y: min(max(ry, 0), 1))
    }

    /// The first intersection of the ray from `origin` (outside the shape) toward `target` entering "the shape's outline expanded outward by `gap`",
    /// so the intersection's distance from the shape is `gap` (Excalidraw's binding gap). Returns nil if the origin is inside it or there is no intersection.
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
        guard tMin <= tMax, tMax >= 0, tMin >= 0 else { return nil } // tMin < 0: the origin is inside the shape
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
        // Offsetting a diamond's edges outward by gap = scaling about the center so the center-to-edge distance grows by gap
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
    // MARK: Creating and removing bindings

    /// Binds one end of an arrow to a shape and moves the endpoint to `gap` outside the shape's outline.
    /// When `fixedPoint` (a 0...1 position on the shape) is omitted, the current endpoint's projection onto the shape is used.
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
        // When the other end is also bound to the same shape, boundElements must be kept
        let other: ArrowEnd = end == .start ? .end : .start
        if self[arrowID]?.binding(other)?.elementId != target { removeBound(arrowID, from: target) }
    }

    // MARK: Recompute endpoints

    /// Recomputes the bound endpoints of arrows bound to `movedIDs`; changes only points that need it, and arrows that did not change do not increment version.
    /// A curved arrow moves only its endpoints and leaves the middle points; the routing of an elbow arrow must be redone and is out of scope, so it is kept as is.
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

    /// Endpoint: bound to a connection point → that edge's midpoint moved out by `gap` (an arrow arriving from behind also stops on this edge);
    /// otherwise → the ray from `origin` toward `anchor` entering `gap` outside the outline; when the ray does not hit the outline the anchor is used directly
    private func endpoint(shape: Element, binding b: Binding, anchor: CGPoint, origin: CGPoint) -> CGPoint {
        if let ratio = b.fixedPoint, let side = Geometry.side(ratio) {
            return Geometry.sideEndpoint(shape, side: side, gap: b.gap)
        }
        return Geometry.entry(from: origin, toward: anchor, shape: shape, gap: b.gap) ?? anchor
    }

    /// The point next to this end: for a multi-point arrow the adjacent point, for a two-point arrow the other end
    private func adjacentPoint(of arrow: Element, _ end: ArrowEnd) -> CGPoint {
        let pts = arrow.absolutePoints
        guard pts.count >= 2 else { return pts.first ?? .zero }
        return end == .start ? pts[1] : pts[pts.count - 2]
    }

    /// The `focus` (-1...1) used by older Excalidraw: the anchor's offset from the center, perpendicular to the arrow direction. Newer versions use `fixedPoint`.
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
