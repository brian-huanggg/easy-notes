import CoreGraphics
import ExcalidrawKit
import Foundation
#if canImport(PencilKit)
import PencilKit
#endif

/// 一頁的筆畫在「頁面座標（elements）」與「overlay 座標（`PKCanvasView`）」之間換算，以及模型 Undo 的快照。
/// 見 architecture/pdf.md「記憶體」「Undo 記在模型」。
enum PageInk {
    /// 變換的線性縮放倍率（旋轉不影響）
    static func scale(of t: CGAffineTransform) -> Double {
        Double(sqrt(abs(t.a * t.d - t.b * t.c)))
    }

    /// overlay 上的筆畫（點已套用 `PKStroke.transform`、點大小還在筆畫自己的座標）換成頁面座標：
    /// 點經 `viewToPage`，點大小乘上兩個變換的縮放（筆畫寬度在頁面上維持畫的時候的視覺粗細）
    static func toPage(_ stroke: InkStroke, strokeScale: Double, viewToPage: CGAffineTransform) -> InkStroke {
        var out = stroke
        let k = strokeScale * scale(of: viewToPage)
        out.points = stroke.points.map { p in
            var q = p
            let loc = CGPoint(x: p.x, y: p.y).applying(viewToPage)
            q.x = Double(loc.x)
            q.y = Double(loc.y)
            q.size = p.size * k
            return q
        }
        return out
    }

    /// 操作前後有變的元素各自的內容（nil = 當時不存在）；以 `version` + `versionNonce` 判斷
    static func snapshots(from old: [[String: Any]], to new: [[String: Any]])
        -> (undo: ExcalidrawScene.Snapshot, redo: ExcalidrawScene.Snapshot) {
        let before = Dictionary(old.compactMap { el in (el["id"] as? String).map { ($0, el) } },
                                uniquingKeysWith: { a, _ in a })
        var undo: ExcalidrawScene.Snapshot = [:], redo: ExcalidrawScene.Snapshot = [:]
        for el in new {
            guard let id = el["id"] as? String else { continue }
            let o = before[id]
            if let o, stamp(o) == stamp(el) { continue }
            // 不能用 `undo[id] = o`：o 為 nil 時是移除這個 key
            undo.updateValue(o, forKey: id)
            redo.updateValue(el, forKey: id)
        }
        return (undo, redo)
    }

    private static func stamp(_ raw: [String: Any]) -> [Int] {
        [(raw["version"] as? NSNumber)?.intValue ?? 0, (raw["versionNonce"] as? NSNumber)?.intValue ?? 0]
    }
}

#if canImport(PencilKit)
extension PageInk {
    /// 頁面的筆畫 → overlay 上的 `PKDrawing`（以 `PKStroke.transform` 換算，PencilKit 依它縮放筆寬）
    static func drawing(_ scene: ExcalidrawScene, pageToView: CGAffineTransform) -> PKDrawing {
        scene.drawing.transformed(using: pageToView)
    }

    /// overlay 上的 `PKDrawing` → 頁面座標的筆畫
    static func strokes(_ drawing: PKDrawing, viewToPage: CGAffineTransform) -> [InkStroke] {
        drawing.strokes.map { stroke in
            toPage(InkStroke(stroke), strokeScale: scale(of: stroke.transform), viewToPage: viewToPage)
        }
    }
}
#endif
