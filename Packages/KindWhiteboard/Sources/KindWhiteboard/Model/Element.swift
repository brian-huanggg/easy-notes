import CoreGraphics
import Foundation

public enum ElementType: Equatable, Sendable {
    case rectangle, diamond, ellipse, line, arrow, text, freedraw, image, frame
    case unknown(String)

    public init(_ name: String) {
        switch name {
        case "rectangle": self = .rectangle
        case "diamond": self = .diamond
        case "ellipse": self = .ellipse
        case "line": self = .line
        case "arrow": self = .arrow
        case "text": self = .text
        case "freedraw": self = .freedraw
        case "image": self = .image
        case "frame": self = .frame
        default: self = .unknown(name)
        }
    }

    /// 可以當文字容器、箭頭綁定目標的形狀
    public var isBindableShape: Bool {
        switch self {
        case .rectangle, .diamond, .ellipse, .image, .text: true
        default: false
        }
    }
}

/// 箭頭端點對形狀的綁定（`startBinding` / `endBinding`）
public struct Binding: Equatable {
    public var elementId: String
    public var focus: Double
    public var gap: Double
    /// 端點在形狀上的位置，0...1 的比例（形狀未旋轉時的座標）
    public var fixedPoint: CGPoint?

    public init(elementId: String, focus: Double = 0, gap: Double = 5, fixedPoint: CGPoint? = nil) {
        self.elementId = elementId; self.focus = focus; self.gap = gap; self.fixedPoint = fixedPoint
    }
}

public enum ArrowEnd: Sendable {
    case start, end

    var key: String { self == .start ? "startBinding" : "endBinding" }
}

/// 型別化的元素包裝。底層仍是原始字典：不認識的欄位與類型原樣保留，寫回時不會遺失。
/// setter 只改欄位，不遞增 version；要遞增請走 `ExcalidrawScene.mutate`。
public struct Element {
    public internal(set) var raw: [String: Any]

    public init(raw: [String: Any]) {
        self.raw = raw
    }

    // MARK: 共用欄位

    public var id: String { raw["id"] as? String ?? "" }
    public var type: ElementType { ElementType(raw["type"] as? String ?? "") }
    public var x: Double { get { num("x") } set { raw["x"] = newValue } }
    public var y: Double { get { num("y") } set { raw["y"] = newValue } }
    public var width: Double { get { num("width") } set { raw["width"] = newValue } }
    public var height: Double { get { num("height") } set { raw["height"] = newValue } }
    public var angle: Double { get { num("angle") } set { raw["angle"] = newValue } }
    public var isDeleted: Bool { get { raw["isDeleted"] as? Bool ?? false } set { raw["isDeleted"] = newValue } }
    public var version: Int { Int(num("version", default: 1)) }
    public var versionNonce: Int { Int(num("versionNonce")) }
    public var updated: Int { Int(num("updated")) }
    public var index: String? { get { raw["index"] as? String } set { raw["index"] = newValue ?? NSNull() } }
    public var link: String? { get { raw["link"] as? String } set { raw["link"] = newValue ?? NSNull() } }
    public var locked: Bool { raw["locked"] as? Bool ?? false }
    public var customData: [String: Any]? { raw["customData"] as? [String: Any] }

    public var groupIds: [String] {
        get { raw["groupIds"] as? [String] ?? [] }
        set { raw["groupIds"] = newValue }
    }

    public var frameId: String? {
        get { raw["frameId"] as? String }
        set { raw["frameId"] = newValue ?? NSNull() }
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

    /// `boundElements`：綁在這個形狀上的箭頭與文字
    public var boundElements: [(id: String, type: String)] {
        get {
            (raw["boundElements"] as? [[String: Any]] ?? []).compactMap { e in
                guard let id = e["id"] as? String, let type = e["type"] as? String else { return nil }
                return (id, type)
            }
        }
        set {
            raw["boundElements"] = newValue.isEmpty ? NSNull() : newValue.map { ["id": $0.id, "type": $0.type] }
        }
    }

    // MARK: text

    public var text: String { raw["text"] as? String ?? "" }
    public var originalText: String { raw["originalText"] as? String ?? text }
    public var fontSize: Double { num("fontSize", default: 20) }
    public var lineHeight: Double { num("lineHeight", default: 1.25) }
    public var textAlign: String { raw["textAlign"] as? String ?? "left" }
    public var verticalAlign: String { raw["verticalAlign"] as? String ?? "top" }
    /// 文字綁定的容器形狀
    public var containerId: String? {
        get { raw["containerId"] as? String }
        set { raw["containerId"] = newValue ?? NSNull() }
    }

    // MARK: line / arrow

    /// 相對於 (x, y) 的點
    public var points: [CGPoint] {
        get {
            (raw["points"] as? [[Any]] ?? []).compactMap { p in
                guard p.count >= 2, let dx = (p[0] as? NSNumber)?.doubleValue, let dy = (p[1] as? NSNumber)?.doubleValue
                else { return nil }
                return CGPoint(x: dx, y: dy)
            }
        }
        set { raw["points"] = newValue.map { [Double($0.x), Double($0.y)] } }
    }

    /// 絕對座標的點（未考慮 `angle`，線與箭頭一律 0）
    public var absolutePoints: [CGPoint] {
        points.map { CGPoint(x: x + $0.x, y: y + $0.y) }
    }

    public var isElbowArrow: Bool { raw["elbowed"] as? Bool == true }

    /// 以絕對座標設定所有點：原點移到第一個點，`width` / `height` 為點的範圍
    public mutating func setAbsolutePoints(_ pts: [CGPoint]) {
        guard let first = pts.first else { return }
        let rel = pts.map { CGPoint(x: $0.x - first.x, y: $0.y - first.y) }
        let xs = rel.map(\.x), ys = rel.map(\.y)
        x = first.x
        y = first.y
        points = rel
        width = (xs.max() ?? 0) - (xs.min() ?? 0)
        height = (ys.max() ?? 0) - (ys.min() ?? 0)
    }

    public func binding(_ end: ArrowEnd) -> Binding? {
        guard let b = raw[end.key] as? [String: Any], let id = b["elementId"] as? String else { return nil }
        var fixed: CGPoint?
        if let f = b["fixedPoint"] as? [Any], f.count >= 2,
           let fx = (f[0] as? NSNumber)?.doubleValue, let fy = (f[1] as? NSNumber)?.doubleValue {
            fixed = CGPoint(x: fx, y: fy)
        }
        return Binding(elementId: id, focus: (b["focus"] as? NSNumber)?.doubleValue ?? 0,
                       gap: (b["gap"] as? NSNumber)?.doubleValue ?? 5, fixedPoint: fixed)
    }

    /// 寫入綁定；綁定字典裡不認識的欄位保留
    public mutating func setBinding(_ end: ArrowEnd, _ binding: Binding?) {
        guard let binding else { raw[end.key] = NSNull(); return }
        var dict = raw[end.key] as? [String: Any] ?? [:]
        dict["elementId"] = binding.elementId
        dict["focus"] = binding.focus
        dict["gap"] = binding.gap
        if let f = binding.fixedPoint { dict["fixedPoint"] = [Double(f.x), Double(f.y)] }
        raw[end.key] = dict
    }

    // MARK: image

    public var fileId: String? { raw["fileId"] as? String }

    // MARK: 修改

    /// 遞增 `version`、重抽 `versionNonce`、更新 `updated`
    mutating func touch() {
        raw["version"] = version + 1
        raw["versionNonce"] = Int.random(in: 1...Int(Int32.max))
        raw["updated"] = Int(Date().timeIntervalSince1970 * 1000)
    }

    func isEqual(to other: Element) -> Bool {
        NSDictionary(dictionary: raw).isEqual(to: other.raw)
    }

    private func num(_ key: String, default value: Double = 0) -> Double {
        (raw[key] as? NSNumber)?.doubleValue ?? value
    }
}

// MARK: 建立新元素

extension Element {
    private static func base(_ type: String, x: Double, y: Double, width: Double, height: Double) -> [String: Any] {
        [
            "type": type,
            "id": ExcalidrawScene.randomID(),
            "x": x, "y": y, "width": width, "height": height,
            "angle": 0,
            "strokeColor": "#1e1e1e",
            "backgroundColor": "transparent",
            "fillStyle": "solid",
            "strokeWidth": 2,
            "strokeStyle": "solid",
            "roughness": 0,
            "opacity": 100,
            "groupIds": [String](),
            "frameId": NSNull(),
            "roundness": NSNull(),
            "seed": Int.random(in: 1...Int(Int32.max)),
            "version": 1,
            "versionNonce": Int.random(in: 1...Int(Int32.max)),
            "isDeleted": false,
            "boundElements": NSNull(),
            "updated": Int(Date().timeIntervalSince1970 * 1000),
            "link": NSNull(),
            "locked": false,
        ]
    }

    public static func rectangle(x: Double, y: Double, width: Double, height: Double) -> Element {
        var raw = base("rectangle", x: x, y: y, width: width, height: height)
        raw["roundness"] = ["type": 3]
        return Element(raw: raw)
    }

    public static func ellipse(x: Double, y: Double, width: Double, height: Double) -> Element {
        Element(raw: base("ellipse", x: x, y: y, width: width, height: height))
    }

    /// 直線箭頭，從 `from` 到 `to`（絕對座標）
    public static func arrow(from: CGPoint, to: CGPoint) -> Element {
        var raw = base("arrow", x: from.x, y: from.y, width: abs(to.x - from.x), height: abs(to.y - from.y))
        raw["roundness"] = ["type": 2]
        raw["points"] = [[0.0, 0.0], [Double(to.x - from.x), Double(to.y - from.y)]]
        raw["lastCommittedPoint"] = NSNull()
        raw["startBinding"] = NSNull()
        raw["endBinding"] = NSNull()
        raw["startArrowhead"] = NSNull()
        raw["endArrowhead"] = "arrow"
        raw["elbowed"] = false
        return Element(raw: raw)
    }

    /// 文字元素；尺寸由 `ExcalidrawScene.setText` 依排版決定
    public static func text(_ text: String, x: Double, y: Double, fontSize: Double = 20) -> Element {
        var raw = base("text", x: x, y: y, width: 0, height: 0)
        raw["text"] = text
        raw["originalText"] = text
        raw["fontSize"] = fontSize
        raw["fontFamily"] = 2 // Helvetica；顯示時一律用系統字型
        raw["textAlign"] = "left"
        raw["verticalAlign"] = "top"
        raw["containerId"] = NSNull()
        raw["autoResize"] = true
        raw["lineHeight"] = 1.25
        var el = Element(raw: raw)
        TextLayout.fit(&el, maxWidth: nil)
        return el
    }

    public static func frame(x: Double, y: Double, width: Double, height: Double, name: String? = nil) -> Element {
        var raw = base("frame", x: x, y: y, width: width, height: height)
        raw["strokeColor"] = "#bbb"
        raw["name"] = name ?? NSNull()
        return Element(raw: raw)
    }

    public static func image(fileId: String, x: Double, y: Double, width: Double, height: Double) -> Element {
        var raw = base("image", x: x, y: y, width: width, height: height)
        raw["fileId"] = fileId
        raw["status"] = "saved"
        raw["scale"] = [1, 1]
        raw["crop"] = NSNull()
        return Element(raw: raw)
    }
}
