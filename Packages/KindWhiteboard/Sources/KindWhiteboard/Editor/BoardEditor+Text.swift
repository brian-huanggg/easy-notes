import CoreGraphics
import ExcalidrawKit
import Foundation

/// 正在用原生文字框編輯的文字。編輯器只記錄目標與樣式；文字框（iOS `UITextView`、Mac `NSTextView`）
/// 由宿主依 `rect(for:)` 疊在畫布上，輸入過程不碰場景（注音組字中不打斷），結束時才 `endTextEditing` 寫回。
struct TextEditing: Equatable {
    /// 既有的文字元素（新文字為 nil）
    var id: String?
    /// 所在的形狀（形狀內的文字，含還沒有文字的形狀）
    var containerId: String?
    /// 開始編輯時的內容（未換行的 `originalText`）
    var text: String
    /// 獨立文字的左上角
    var origin: CGPoint
    /// 形狀內的文字：容器中心（文字框置中）與可用寬度
    var center: CGPoint?
    var maxWidth: Double?
    var fontSize: Double
    var lineHeight: Double
    var align: String
    var color: String
    var angle: Double

    /// 文字框在畫布座標中的位置（未旋轉；繞中心轉 `angle`）。排版與模型相同（`TextLayout`），
    /// 所以編輯中的換行與結束後一致
    func rect(for text: String) -> CGRect {
        let size = TextLayout.layout(text, fontSize: fontSize, lineHeight: lineHeight, maxWidth: maxWidth).size
        let height = max(size.height, fontSize * lineHeight)
        if let center, let maxWidth {
            return CGRect(x: center.x - maxWidth / 2, y: center.y - height / 2, width: maxWidth, height: height)
        }
        return CGRect(x: origin.x, y: origin.y, width: maxWidth ?? size.width, height: height)
    }
}

/// 文字編輯與插入圖片
extension BoardEditor {
    /// 新文字的預設值
    static let defaultFontSize: Double = 20
    static let defaultTextColor = "#1e1e1e"

    // MARK: 文字

    /// 在 `p` 編輯文字：點到文字 → 編輯它；點到矩形、橢圓、菱形 → 編輯（或新增）形狀內的文字；
    /// 其他地方 → 新文字，插入點在 `p` 垂直置中。文字工具點一下、選取工具雙擊時呼叫。
    @discardableResult
    func editText(at p: CGPoint) -> Bool {
        guard textEditing == nil else { return false }
        if let hit = element(at: p), editText(of: hit) { return true }
        newText(at: p)
        return true
    }

    /// 開始一段新文字，插入點在 `p` 垂直置中（不看那裡有沒有元素）
    func newText(at p: CGPoint) {
        guard textEditing == nil else { return }
        let fontSize = currentFontSize
        let lineBox = fontSize * 1.25
        start(TextEditing(text: "", origin: CGPoint(x: p.x, y: p.y - lineBox / 2),
                          fontSize: fontSize, lineHeight: 1.25, align: currentTextAlign(default: "left"),
                          color: currentTextColor, angle: 0))
    }

    /// 編輯文字元素，或形狀內的文字（沒有就新增）。其他元素回傳 false
    @discardableResult
    func editText(of id: String) -> Bool {
        guard textEditing == nil, let el = document.scene.element(id), !el.isDeleted, !el.locked else { return false }
        switch el.type {
        case .text:
            if let container = el.containerId, let c = document.scene.element(container), !c.isDeleted {
                start(Self.editing(el, in: c))
            } else {
                start(Self.editing(el, in: nil))
            }
        case .rectangle, .ellipse, .diamond:
            if let bound = document.scene.liveElements.first(where: { $0.containerId == id && $0.type == .text }) {
                start(Self.editing(bound, in: el))
            } else {
                var editing = TextEditing(text: "", origin: el.center, fontSize: currentFontSize, lineHeight: 1.25,
                                          align: currentTextAlign(default: "center"), color: currentTextColor,
                                          angle: el.angle)
                editing.containerId = id
                editing.center = el.center
                editing.maxWidth = TextLayout.maxWidth(in: el)
                start(editing)
            }
        default:
            return false
        }
        return true
    }

    /// 結束編輯，寫回 `text`：空白的新文字不建立、既有文字刪除（形狀保留）；之後選取工具並選取它
    /// （形狀內的文字選取容器）。整次編輯一筆 Undo
    func endTextEditing(_ text: String) {
        guard let editing = textEditing else { return }
        textEditing = nil
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var selected: String?
        perform { scene in
            if let id = editing.id, let el = scene.element(id), !el.isDeleted {
                if empty {
                    scene.delete([id])
                } else {
                    scene.setText(id, to: text)
                    selected = el.containerId ?? id
                }
            } else if let container = editing.containerId, scene.element(container)?.isDeleted == false {
                if !empty, let id = scene.addBoundText(text, to: container) {
                    // 新增的文字沿用文字框的樣式（上次的樣式）；改字級會重新排版
                    for change in [StyleChange.textColor(editing.color), .textAlign(editing.align), .fontSize(editing.fontSize)] {
                        scene.setStyle([id], change)
                    }
                    selected = container
                }
            } else if !empty {
                // 新文字，或編輯中被外部刪除的文字：放在原本的位置
                var el = Element.text(text, x: editing.origin.x, y: editing.origin.y, fontSize: editing.fontSize)
                el.raw["strokeColor"] = editing.color
                el.raw["textAlign"] = editing.align
                if editing.id == nil, case let .opacity(value)? = currentStyle[.opacity] { el.raw["opacity"] = value }
                scene.insert(el)
                selected = el.id
            }
        }
        // 換工具時結束的編輯：不要蓋掉剛選的工具
        if tool == .text, !switchingTool { tool = .select }
        selection = selected.map { [$0] } ?? []
        recordUndo(L("文字"))
    }

    /// 宿主沒有文字框可以結束（例如測試）時，放棄編輯中的內容
    func cancelTextEditing() {
        guard textEditing != nil else { return }
        textEditing = nil
        gestureBefore = []
        onChange?(BoardChange())
    }

    /// 由編輯器自己結束（換工具、其他操作開始）：請宿主交出文字框的內容
    func finishTextEditing(switchingTool: Bool = false) {
        guard textEditing != nil else { return }
        self.switchingTool = switchingTool
        requestTextCommit?()
        self.switchingTool = false
        if textEditing != nil { cancelTextEditing() }
    }

    private func start(_ editing: TextEditing) {
        gestureBefore = document.scene.elements
        gestureSelection = selection
        selection = []
        textEditing = editing
        onChange?(BoardChange())
    }

    private static func editing(_ el: Element, in container: Element?) -> TextEditing {
        var editing = TextEditing(id: el.id, text: el.originalText, origin: CGPoint(x: el.x, y: el.y),
                                  fontSize: el.fontSize, lineHeight: el.lineHeight, align: el.textAlign,
                                  color: el.raw["strokeColor"] as? String ?? defaultTextColor, angle: el.angle)
        if let container {
            editing.containerId = container.id
            editing.center = container.center
            editing.maxWidth = TextLayout.maxWidth(in: container)
            editing.angle = container.angle
        } else if el.raw["autoResize"] as? Bool == false {
            editing.maxWidth = el.width
        }
        return editing
    }

    // MARK: 圖片

    /// 插入圖片：背景解碼與縮圖，中心放在 `center`（預設畫面中央；拖放時是放開的位置），顯示尺寸最長邊約螢幕上 400 點。
    /// 之後選取工具並選取它。資料不是圖片回傳 false
    @discardableResult
    func insertImage(_ data: Data, center: CGPoint? = nil) async -> Bool {
        let encoded = await Task.detached(priority: .userInitiated) { ExcalidrawScene.downscale(data) }.value
        guard let encoded else { return false }
        let center = center ?? (visibleRect.isNull ? .zero : CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        let maxDisplay = 400 / Double(max(zoom, 0.01))
        inking = false
        tool = .select
        operation(L("插入圖片"), select: { [$0] }) { $0.insertImage(encoded, center: center, maxDisplay: maxDisplay) }
        return true
    }
}
