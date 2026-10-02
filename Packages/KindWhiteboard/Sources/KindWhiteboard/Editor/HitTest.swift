import CoreGraphics
import Foundation

/// 點選判定（畫布座標）。`tolerance` 是畫布單位：宿主以螢幕上固定的點數除以縮放倍率。
enum HitTest {
    /// 可以被選取的元素：手寫交給 PencilKit（Mac 只能看），`locked` 不能選
    static func isSelectable(_ el: Element) -> Bool {
        !el.isDeleted && !el.locked && el.type != .freedraw
    }

    /// 套索選取用的取樣點（畫布座標，含旋轉）：形狀取輪廓路徑的節點、線與箭頭取各點、其他取四角。
    /// 全部落在套索內才算選到
    static func samplePoints(_ el: Element) -> [CGPoint] {
        let t = ElementGeometry.rotation(el)
        switch el.type {
        case .line, .arrow, .freedraw:
            return el.absolutePoints.map { $0.applying(t) }
        case .rectangle, .ellipse, .diamond, .frame:
            var nodes: [CGPoint] = []
            ElementGeometry.outline(el).applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint, .addLineToPoint: nodes.append(e.points[0])
                case .addQuadCurveToPoint: nodes.append(e.points[1])
                case .addCurveToPoint: nodes.append(e.points[2])
                default: break
                }
            }
            return nodes.map { $0.applying(t) }
        default:
            let r = el.rect.standardized
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { $0.applying(t) }
        }
    }

    /// 元素是否被點到。有填色的形狀、文字、圖片點內部即可；透明形狀與 frame 只點得到邊框
    /// （frame 另含標題）；`selected` 的元素點內部也算。
    static func hits(_ el: Element, _ p: CGPoint, tolerance: Double, selected: Bool = false) -> Bool {
        guard ElementGeometry.bounds(el).insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
        let local = p.applying(ElementGeometry.rotation(el).inverted())
        switch el.type {
        case .freedraw:
            return false
        case .text, .image, .unknown:
            return el.rect.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(local)
        case .line, .arrow:
            let path = ElementGeometry.linePath(el)
            if ElementGeometry.isClosedLine(el), isFilled(el) || selected, path.contains(local) { return true }
            return stroke(path, el, tolerance).contains(local)
        case .frame:
            if selected, el.rect.standardized.contains(local) { return true }
            if ElementGeometry.frameTitleRect(el).contains(local) { return true }
            return stroke(ElementGeometry.outline(el), el, tolerance).contains(local)
        case .rectangle, .ellipse, .diamond:
            let outline = ElementGeometry.outline(el)
            if isFilled(el) || selected, outline.contains(local) { return true }
            return stroke(outline, el, tolerance).contains(local)
        }
    }

    /// 箭頭可以綁上去的形狀：在輪廓內或輪廓外 `tolerance` 以內
    static func bindable(_ el: Element, _ p: CGPoint, tolerance: Double) -> Bool {
        guard el.type.isBindableShape, el.containerId == nil, !el.isDeleted,
              ElementGeometry.bounds(el).insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
        let local = p.applying(ElementGeometry.rotation(el).inverted())
        let outline = el.type == .text || el.type == .image
            ? CGPath(rect: el.rect.standardized, transform: nil) : ElementGeometry.outline(el)
        return outline.contains(local) || stroke(outline, el, tolerance).contains(local)
    }

    static func isFilled(_ el: Element) -> Bool {
        SceneColor.parse(el.raw["backgroundColor"] as? String ?? "transparent") != nil
    }

    private static func stroke(_ path: CGPath, _ el: Element, _ tolerance: Double) -> CGPath {
        path.copy(strokingWithWidth: ElementGeometry.strokeWidth(el) + tolerance * 2,
                  lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}
