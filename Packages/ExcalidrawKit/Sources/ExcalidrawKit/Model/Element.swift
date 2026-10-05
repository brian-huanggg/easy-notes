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

    /// Shapes that can serve as text containers and arrow binding targets
    public var isBindableShape: Bool {
        switch self {
        case .rectangle, .diamond, .ellipse, .image, .text: true
        default: false
        }
    }
}

/// An arrow endpoint's binding to a shape (`startBinding` / `endBinding`)
public struct Binding: Equatable {
    public var elementId: String
    public var focus: Double
    public var gap: Double
    /// The endpoint's position on the shape, a 0...1 ratio (coordinates when the shape is unrotated)
    public var fixedPoint: CGPoint?

    public init(elementId: String, focus: Double = 0, gap: Double = 5, fixedPoint: CGPoint? = nil) {
        self.elementId = elementId; self.focus = focus; self.gap = gap; self.fixedPoint = fixedPoint
    }
}

public enum ArrowEnd: Sendable {
    case start, end

    var key: String { self == .start ? "startBinding" : "endBinding" }
}

/// A typed element wrapper. The underlying value is still a raw dictionary: unknown fields and types are preserved and not lost on write-back.
/// Setters only change fields and do not increment version; to increment, go through `ExcalidrawScene.mutate`.
public struct Element {
    public var raw: [String: Any]

    public init(raw: [String: Any]) {
        self.raw = raw
    }

    // MARK: Shared fields

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

    /// `boundElements`: arrows and text bound to this shape
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
    /// The container shape the text is bound to
    public var containerId: String? {
        get { raw["containerId"] as? String }
        set { raw["containerId"] = newValue ?? NSNull() }
    }

    // MARK: line / arrow

    /// Points relative to (x, y)
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

    /// Points in absolute coordinates (not accounting for `angle`; always 0 for lines and arrows)
    public var absolutePoints: [CGPoint] {
        points.map { CGPoint(x: x + $0.x, y: y + $0.y) }
    }

    public var isElbowArrow: Bool { raw["elbowed"] as? Bool == true }

    /// Sets all points in absolute coordinates: the origin moves to the first point and `width` / `height` are the points' extent
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

    /// Writes the binding; unknown fields inside the binding dictionary are kept
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

    // MARK: Modify

    /// Increments `version`, redraws `versionNonce`, updates `updated`
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

// MARK: Creating new elements

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

    public static func rectangle(x: Double, y: Double, width: Double, height: Double, rounded: Bool = true) -> Element {
        var raw = base("rectangle", x: x, y: y, width: width, height: height)
        if rounded { raw["roundness"] = ["type": 3] }
        return Element(raw: raw)
    }

    public static func diamond(x: Double, y: Double, width: Double, height: Double) -> Element {
        Element(raw: base("diamond", x: x, y: y, width: width, height: height))
    }

    /// Sticky note: a borderless, yellow-filled square-cornered rectangle (text sits inside it through `containerId`)
    public static func stickyNote(x: Double, y: Double, size: Double) -> Element {
        var el = rectangle(x: x, y: y, width: size, height: size, rounded: false)
        el.raw["backgroundColor"] = "#ffec99"
        el.raw["strokeColor"] = "transparent"
        return el
    }

    public static func ellipse(x: Double, y: Double, width: Double, height: Double) -> Element {
        Element(raw: base("ellipse", x: x, y: y, width: width, height: height))
    }

    /// A straight arrow from `from` to `to` (absolute coordinates)
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

    /// A text element; the size is decided by layout in `ExcalidrawScene.setText`
    public static func text(_ text: String, x: Double, y: Double, fontSize: Double = 20) -> Element {
        var raw = base("text", x: x, y: y, width: 0, height: 0)
        raw["text"] = text
        raw["originalText"] = text
        raw["fontSize"] = fontSize
        raw["fontFamily"] = 2 // Helvetica; display always uses system fonts
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
