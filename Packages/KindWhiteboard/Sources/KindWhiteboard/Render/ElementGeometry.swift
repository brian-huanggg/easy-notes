import CoreGraphics
import Foundation

/// 元素的幾何：輪廓、線段、箭頭頭部與畫面範圍（畫布座標、未旋轉）。
/// `SceneRenderer` 與 4c 編輯器的 layer 樹共用這一份，所以兩邊畫出來的形狀一致。
/// 數值照 Excalidraw（圓角、箭頭大小與角度），但線條是乾淨的，不模擬 rough.js。
public enum ElementGeometry {
    // MARK: 旋轉中心與範圍

    /// 未旋轉時的外框。線、箭頭、手寫是點的範圍（點可能在 (x, y) 的左上方）
    public static func box(_ el: Element) -> CGRect {
        switch el.type {
        case .line, .arrow, .freedraw:
            let pts = el.absolutePoints
            guard let first = pts.first else { return CGRect(x: el.x, y: el.y, width: 0, height: 0) }
            var r = CGRect(origin: first, size: .zero)
            for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        default:
            return el.rect.standardized
        }
    }

    /// `angle` 的旋轉中心（與 Excalidraw 相同：外框中心）
    public static func center(_ el: Element) -> CGPoint {
        let b = box(el)
        return CGPoint(x: b.midX, y: b.midY)
    }

    /// 畫布座標 → 元素未旋轉時的座標
    public static func rotation(_ el: Element) -> CGAffineTransform {
        guard el.angle != 0 else { return .identity }
        let c = center(el)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: el.angle).translatedBy(x: -c.x, y: -c.y)
    }

    /// 畫面上佔的範圍（含旋轉、線寬、箭頭頭部與 frame 標題），用來裁切畫面外的元素與計算縮圖範圍
    public static func bounds(_ el: Element) -> CGRect {
        var r = paddedBox(el)
        if el.angle != 0 { r = r.applying(rotation(el)) }
        return r
    }

    /// 所有元素畫到的範圍；沒有元素回傳 nil
    public static func bounds(of elements: [Element]) -> CGRect? {
        elements.reduce(nil) { acc, el in acc.map { $0.union(bounds(el)) } ?? bounds(el) }
    }

    /// 未旋轉時畫到的範圍（含線寬、箭頭頭部與 frame 標題）。layer 樹以它當每個元素 layer 的 bounds
    public static func paddedBox(_ el: Element) -> CGRect {
        let stroke = (el.raw["strokeWidth"] as? NSNumber)?.doubleValue ?? 2
        var outset = stroke / 2 + 1
        switch el.type {
        case .arrow, .line:
            if el.raw["startArrowhead"] is String || el.raw["endArrowhead"] is String { outset += 13 }
        case .freedraw:
            outset = max(outset, freedrawMaxWidth(el) / 2 + 1)
        default: break
        }
        var r = box(el).insetBy(dx: -outset, dy: -outset)
        if el.type == .frame { r = r.union(frameTitleRect(el)) }
        return r
    }

    // MARK: 形狀輪廓

    /// Excalidraw 的圓角：`roundness.type` 3 = 固定半徑（預設 32，小形狀改用 25%），其他 = 25%
    static func cornerRadius(_ size: Double, _ el: Element) -> Double {
        guard let r = el.raw["roundness"] as? [String: Any], let type = (r["type"] as? NSNumber)?.intValue else { return 0 }
        guard type == 3 else { return size * 0.25 }
        let fixed = (r["value"] as? NSNumber)?.doubleValue ?? 32
        return size <= fixed / 0.25 ? size * 0.25 : fixed
    }

    /// 矩形、菱形、橢圓（以及圖片、frame、佔位框用矩形）的輪廓，未旋轉
    public static func outline(_ el: Element) -> CGPath {
        let r = el.rect.standardized
        switch el.type {
        case .ellipse:
            return CGPath(ellipseIn: r, transform: nil)
        case .diamond:
            return diamond(r, el)
        case .frame:
            return CGPath(roundedRect: r, cornerWidth: min(8, r.width / 2), cornerHeight: min(8, r.height / 2), transform: nil)
        default:
            let radius = min(cornerRadius(min(r.width, r.height), el), r.width / 2, r.height / 2)
            guard radius > 0 else { return CGPath(rect: r, transform: nil) }
            // 與 Excalidraw 相同用二次曲線，不是圓弧
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
            p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
            p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }

    private static func diamond(_ r: CGRect, _ el: Element) -> CGPath {
        let top = CGPoint(x: r.midX, y: r.minY), right = CGPoint(x: r.maxX, y: r.midY)
        let bottom = CGPoint(x: r.midX, y: r.maxY), left = CGPoint(x: r.minX, y: r.midY)
        let p = CGMutablePath()
        guard el.raw["roundness"] is [String: Any] else {
            p.addLines(between: [top, right, bottom, left])
            p.closeSubpath()
            return p
        }
        // 與 Excalidraw 相同：每個頂點用兩個控制點都在頂點上的三次曲線
        let v = cornerRadius(r.width / 2, el), h = cornerRadius(r.height / 2, el)
        p.move(to: CGPoint(x: top.x + v, y: top.y + h))
        p.addLine(to: CGPoint(x: right.x - v, y: right.y - h))
        p.addCurve(to: CGPoint(x: right.x - v, y: right.y + h), control1: right, control2: right)
        p.addLine(to: CGPoint(x: bottom.x + v, y: bottom.y - h))
        p.addCurve(to: CGPoint(x: bottom.x - v, y: bottom.y - h), control1: bottom, control2: bottom)
        p.addLine(to: CGPoint(x: left.x + v, y: left.y + h))
        p.addCurve(to: CGPoint(x: left.x + v, y: left.y - h), control1: left, control2: left)
        p.addLine(to: CGPoint(x: top.x - v, y: top.y + h))
        p.addCurve(to: CGPoint(x: top.x + v, y: top.y + h), control1: top, control2: top)
        p.closeSubpath()
        return p
    }

    // MARK: 線與箭頭

    /// 線或箭頭是否畫成曲線：有 `roundness` 且不是 elbow 箭頭
    static func isCurved(_ el: Element) -> Bool {
        el.raw["roundness"] is [String: Any] && !el.isElbowArrow
    }

    /// 線與箭頭的路徑。曲線用 Catmull-Rom（與 rough.js 的 curve 相同），否則為折線
    public static func linePath(_ el: Element) -> CGPath {
        let pts = el.absolutePoints
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if isCurved(el), pts.count > 2 {
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
                p.addCurve(to: p2,
                           control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                           control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            }
        } else {
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
        if isClosedLine(el) { p.closeSubpath() }
        return p
    }

    /// 首尾相接的線（`polygon` 或兩端距離 ≤ 8，與 Excalidraw 相同）可以填色
    static func isClosedLine(_ el: Element) -> Bool {
        guard el.type == .line else { return false }
        if el.raw["polygon"] as? Bool == true { return true }
        let pts = el.points
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= 8
    }

    /// 箭頭頭部的一個部件：`fill` = 用線條顏色填滿，否則只描邊
    public struct Arrowhead {
        public var path: CGPath
        public var fill: Bool
    }

    /// 兩端的箭頭頭部（`startArrowhead` / `endArrowhead`）
    public static func arrowheads(_ el: Element) -> [Arrowhead] {
        let pts = el.absolutePoints
        guard pts.count >= 2 else { return [] }
        var result: [Arrowhead] = []
        if let kind = el.raw["startArrowhead"] as? String {
            result += arrowhead(kind, tip: pts[0], from: pts[1], strokeWidth: strokeWidth(el))
        }
        if let kind = el.raw["endArrowhead"] as? String {
            result += arrowhead(kind, tip: pts[pts.count - 1], from: pts[pts.count - 2], strokeWidth: strokeWidth(el))
        }
        return result
    }

    static func strokeWidth(_ el: Element) -> Double {
        (el.raw["strokeWidth"] as? NSNumber)?.doubleValue ?? 2
    }

    /// 曲線在端點的切線方向等於最後一段線段的方向（Catmull-Rom 端點重複），所以直線與曲線共用
    static func arrowhead(_ kind: String, tip: CGPoint, from prev: CGPoint, strokeWidth: Double) -> [Arrowhead] {
        let length = hypot(tip.x - prev.x, tip.y - prev.y)
        guard length > 0 else { return [] }
        let dir = CGPoint(x: (tip.x - prev.x) / length, y: (tip.y - prev.y) / length)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let base: Double = switch kind {
        case "arrow": 25
        case "diamond", "diamond_outline": 12
        case "crowfoot_one", "crowfoot_many", "crowfoot_one_or_many": 20
        default: 15
        }
        let size = min(base, length * (kind.hasPrefix("diamond") ? 0.25 : 0.5))
        let angle = (kind == "arrow" ? 20.0 : 25.0) * .pi / 180
        func back(_ d: Double, side: Double = 0) -> CGPoint {
            CGPoint(x: tip.x - dir.x * d + perp.x * side, y: tip.y - dir.y * d + perp.y * side)
        }
        func lines(_ segments: [(CGPoint, CGPoint)]) -> Arrowhead {
            let p = CGMutablePath()
            for (a, b) in segments { p.move(to: a); p.addLine(to: b) }
            return Arrowhead(path: p, fill: false)
        }
        func polygon(_ pts: [CGPoint], fill: Bool) -> Arrowhead {
            let p = CGMutablePath()
            p.addLines(between: pts)
            p.closeSubpath()
            return Arrowhead(path: p, fill: fill)
        }
        let wing = size * tan(angle)

        switch kind {
        case "arrow":
            let l = back(size * cos(angle), side: size * sin(angle)), r = back(size * cos(angle), side: -size * sin(angle))
            return [lines([(l, tip), (r, tip)])]
        case "bar":
            return [lines([(back(0, side: size), back(0, side: -size))])]
        case "triangle", "triangle_outline":
            return [polygon([tip, back(size, side: wing), back(size, side: -wing)], fill: kind == "triangle")]
        case "dot", "circle", "circle_outline":
            let d = size + strokeWidth - 2
            let rect = CGRect(x: tip.x - d / 2, y: tip.y - d / 2, width: d, height: d)
            return [Arrowhead(path: CGPath(ellipseIn: rect, transform: nil), fill: kind != "circle_outline")]
        case "diamond", "diamond_outline":
            return [polygon([tip, back(size, side: size / 2), back(size * 2), back(size, side: -size / 2)],
                            fill: kind == "diamond")]
        case "crowfoot_many", "crowfoot_one_or_many":
            let fork = back(size)
            var parts = [lines([(fork, back(0, side: size / 2)), (fork, back(0, side: -size / 2))])]
            if kind == "crowfoot_one_or_many" { parts.append(lines([(back(size, side: size / 2), back(size, side: -size / 2))])) }
            return parts
        case "crowfoot_one":
            return [lines([(back(size / 2, side: size / 2), back(size / 2, side: -size / 2))])]
        default:
            return [lines([(back(size * cos(angle), side: size * sin(angle)), tip),
                           (back(size * cos(angle), side: -size * sin(angle)), tip)])]
        }
    }

    // MARK: 手寫

    /// 每個點的筆畫寬度。EasyNotes（PencilKit）的筆畫用 `customData` 裡的點大小；
    /// excalidraw.com 畫的照 perfect-freehand（size = strokeWidth × 4.25、thinning 0.6）
    public static func freedrawWidths(_ el: Element) -> [Double] {
        let count = el.points.count
        let custom = el.customData?[ExcalidrawScene.customKey] as? [String: Any]
        if let sizes = (custom?["size"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), sizes.count == count {
            let ink = custom?["ink"] as? String ?? ""
            let factor = ink.hasSuffix("pencil") ? 0.6 : 1
            return sizes.map { max($0 * factor, 0.5) }
        }
        let size = strokeWidth(el) * 4.25
        let pressures = (el.raw["pressures"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        let simulate = el.raw["simulatePressure"] as? Bool ?? pressures.isEmpty
        return (0..<count).map { i in
            let p = simulate ? 0.5 : (pressures[safe: i] ?? 0.5)
            return max(size * (1 - 1.2 * (0.5 - p)), 0.5)
        }
    }

    static func freedrawMaxWidth(_ el: Element) -> Double {
        freedrawWidths(el).max() ?? strokeWidth(el)
    }

    // MARK: frame

    static let frameTitleSize: Double = 14

    /// frame 標題在 frame 左上方外側
    static func frameTitleRect(_ el: Element) -> CGRect {
        CGRect(x: el.x, y: el.y - frameTitleSize * 1.25 - 4, width: max(el.width, 1), height: frameTitleSize * 1.25)
    }
}
