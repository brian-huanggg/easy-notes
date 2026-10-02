import CoreGraphics
import Foundation

/// 樣式面板的一次修改（見 architecture/whiteboard.md「4c：樣式面板」）。全部是 Excalidraw 標準欄位
public enum StyleChange: Equatable, Sendable {
    /// `backgroundColor`
    case fill(String)
    /// `strokeColor`（形狀、線、箭頭）
    case strokeColor(String)
    case strokeWidth(Double)
    /// solid / dashed / dotted
    case strokeStyle(String)
    /// `roundness`：矩形 `{type: 3}`、菱形 `{type: 2}`；直角 = null
    case rounded(Bool)
    /// `startArrowhead` / `endArrowhead`（nil = 無）
    case arrowhead(ArrowEnd, String?)
    /// 文字的 `strokeColor`
    case textColor(String)
    case fontSize(Double)
    /// left / center / right
    case textAlign(String)
    /// 0–100
    case opacity(Double)

    /// 改動的欄位種類（新元素沿用上次的樣式時，同一種只記最後一次）
    var property: StyleProperty {
        switch self {
        case .fill: .fill
        case .strokeColor: .strokeColor
        case .strokeWidth: .strokeWidth
        case .strokeStyle: .strokeStyle
        case .rounded: .rounded
        case let .arrowhead(end, _): end == .start ? .startArrowhead : .endArrowhead
        case .textColor: .textColor
        case .fontSize: .fontSize
        case .textAlign: .textAlign
        case .opacity: .opacity
        }
    }
}

public enum StyleProperty: Hashable, Sendable {
    case fill, strokeColor, strokeWidth, strokeStyle, rounded, startArrowhead, endArrowhead
    case textColor, fontSize, textAlign, opacity
}

extension Element {
    /// 這個元素在樣式面板上可以改的欄位
    var styleProperties: Set<StyleProperty> {
        switch type {
        case .rectangle, .diamond:
            [.fill, .strokeColor, .strokeWidth, .strokeStyle, .rounded, .opacity]
        case .ellipse:
            [.fill, .strokeColor, .strokeWidth, .strokeStyle, .opacity]
        case .arrow:
            [.strokeColor, .strokeWidth, .strokeStyle, .startArrowhead, .endArrowhead, .opacity]
        case .line:
            [.strokeColor, .strokeWidth, .strokeStyle, .opacity]
        case .text:
            [.textColor, .fontSize, .textAlign, .opacity]
        case .image, .freedraw:
            [.opacity]
        default:
            []
        }
    }

    /// 修改一個欄位（不檢查是否適用；文字排版由 `SceneEditor.setStyle` 處理）
    mutating func apply(_ change: StyleChange) {
        switch change {
        case let .fill(color): raw["backgroundColor"] = color
        case let .strokeColor(color), let .textColor(color): raw["strokeColor"] = color
        case let .strokeWidth(width): raw["strokeWidth"] = width
        case let .strokeStyle(style): raw["strokeStyle"] = style
        case let .rounded(on):
            raw["roundness"] = on ? ["type": type == .diamond ? 2 : 3] : NSNull()
        case let .arrowhead(end, kind):
            raw[end == .start ? "startArrowhead" : "endArrowhead"] = kind ?? NSNull()
        case let .fontSize(size): raw["fontSize"] = size
        case let .textAlign(align): raw["textAlign"] = align
        case let .opacity(value): raw["opacity"] = value
        }
    }
}

/// 選取元素目前的樣式：每個欄位收集所有適用元素的值。空集合 = 不適用（面板不顯示），
/// 一個值 = 一致，多個值 = 混合
public struct StyleSummary: Equatable, Sendable {
    public var fills: Set<String> = []
    public var strokeColors: Set<String> = []
    public var strokeWidths: Set<Double> = []
    public var strokeStyles: Set<String> = []
    public var rounded: Set<Bool> = []
    /// 無 = ""
    public var startArrowheads: Set<String> = []
    public var endArrowheads: Set<String> = []
    public var textColors: Set<String> = []
    public var fontSizes: Set<Double> = []
    public var textAligns: Set<String> = []
    public var opacities: Set<Double> = []
    /// 外框可以設成「無」（選取中只有形狀，沒有線或箭頭）
    public var strokeCanBeNone = true

    public var isEmpty: Bool {
        fills.isEmpty && strokeColors.isEmpty && rounded.isEmpty && startArrowheads.isEmpty
            && textColors.isEmpty && opacities.isEmpty
    }

    init(_ elements: [Element]) {
        for el in elements {
            let props = el.styleProperties
            let raw = el.raw
            func string(_ key: String, _ fallback: String) -> String { (raw[key] as? String ?? fallback).lowercased() }
            func number(_ key: String, _ fallback: Double) -> Double { (raw[key] as? NSNumber)?.doubleValue ?? fallback }
            if props.contains(.fill) { fills.insert(string("backgroundColor", "transparent")) }
            if props.contains(.strokeColor) {
                strokeColors.insert(string("strokeColor", "#1e1e1e"))
                if el.type == .line || el.type == .arrow { strokeCanBeNone = false }
            }
            if props.contains(.strokeWidth) { strokeWidths.insert(number("strokeWidth", 2)) }
            if props.contains(.strokeStyle) { strokeStyles.insert(string("strokeStyle", "solid")) }
            if props.contains(.rounded) { rounded.insert(raw["roundness"] is [String: Any]) }
            if props.contains(.startArrowhead) { startArrowheads.insert(raw["startArrowhead"] as? String ?? "") }
            if props.contains(.endArrowhead) { endArrowheads.insert(raw["endArrowhead"] as? String ?? "") }
            if props.contains(.textColor) { textColors.insert(string("strokeColor", "#1e1e1e")) }
            if props.contains(.fontSize) { fontSizes.insert(el.fontSize) }
            if props.contains(.textAlign) { textAligns.insert(el.textAlign) }
            if props.contains(.opacity) { opacities.insert(number("opacity", 100)) }
        }
        if strokeColors.isEmpty { strokeCanBeNone = false }
    }

    public init() {}
}

extension ExcalidrawScene {
    /// 修改 `ids` 的樣式（形狀內的文字算在形狀裡）。只改適用的元素、內容有變才遞增 version
    public mutating func setStyle(_ ids: Set<String>, _ change: StyleChange) {
        edit { $0.setStyle(ids, change) }
    }

    /// `ids` 與它們形狀內文字的樣式
    public func styleSummary(_ ids: Set<String>) -> StyleSummary {
        StyleSummary(styleTargets(ids))
    }

    func styleTargets(_ ids: Set<String>) -> [Element] {
        liveElements.filter { el in
            ids.contains(el.id) || el.containerId.map(ids.contains) == true
        }
    }
}

extension SceneEditor {
    mutating func setStyle(_ ids: Set<String>, _ change: StyleChange) {
        let property = change.property
        // 形狀的透明度也套用到它的文字（與 Excalidraw 相同）；文字欄位套用到選到的形狀內的文字
        let targets = elements.filter { el in
            guard !el.isDeleted else { return false }
            if ids.contains(el.id) { return true }
            guard let container = el.containerId, ids.contains(container) else { return false }
            return el.styleProperties.contains(property)
        }
        var relayout: Set<String> = []
        for el in targets where el.styleProperties.contains(property) {
            let changed = update(el.id) { $0.apply(change) }
            guard changed, el.type == .text, case .fontSize = change else { continue }
            if let container = el.containerId, self[container]?.isDeleted == false {
                relayout.insert(container)
            } else {
                refitText(el.id, from: el)
            }
        }
        for container in relayout where layoutBoundText(in: container) {
            rebindArrows(movedIDs: [container])
        }
    }

    /// 獨立文字改字級後重新排版：依 `textAlign` 固定左緣 / 中心 / 右緣，上緣不動
    private mutating func refitText(_ id: String, from old: Element) {
        update(id) { el in
            TextLayout.fit(&el, maxWidth: el.raw["autoResize"] as? Bool == false ? el.width : nil)
            switch el.textAlign {
            case "center": el.x = old.x + (old.width - el.width) / 2
            case "right": el.x = old.x + old.width - el.width
            default: break
            }
        }
        rebindArrows(movedIDs: [id])
    }
}
