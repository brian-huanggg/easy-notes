import EasyNotesCore
import Foundation

/// 平台無關的手寫筆畫。PencilKit 與 Excalidraw freedraw 之間都經過它轉換。
public struct InkStroke: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var force: Double
        public var size: Double
        public var timeOffset: Double
        public var azimuth: Double
        public var altitude: Double
        public var opacity: Double

        public init(x: Double, y: Double, force: Double = 1, size: Double = 2, timeOffset: Double = 0,
                    azimuth: Double = 0, altitude: Double = .pi / 2, opacity: Double = 1) {
            self.x = x; self.y = y; self.force = force; self.size = size
            self.timeOffset = timeOffset; self.azimuth = azimuth; self.altitude = altitude; self.opacity = opacity
        }
    }

    /// Excalidraw 元素 id；從 PencilKit 來的新筆畫為 nil（PKStroke 沒有穩定 id）
    public var id: String?
    /// PKInk.InkType 的 rawValue，例如 "com.apple.ink.pen"
    public var ink: String
    /// sRGB，格式 "#rrggbb"
    public var color: String
    public var opacity: Double
    public var points: [Point]

    public init(id: String? = nil, ink: String, color: String, opacity: Double = 1, points: [Point]) {
        self.id = id; self.ink = ink; self.color = color; self.opacity = opacity; self.points = points
    }

    /// PencilKit 以 Float 儲存座標，來回轉換會有微小誤差，比對時需要容忍度
    public func matches(_ other: InkStroke, tolerance: Double = 1e-3) -> Bool {
        guard ink == other.ink, color == other.color, points.count == other.points.count else { return false }
        return zip(points, other.points).allSatisfy { a, b in
            abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.force - b.force) < tolerance
        }
    }
}

/// `.excalidraw` 場景。以原始 JSON 字典保存，非 freedraw 元素與未知欄位原封不動寫回，確保格式相容。
public struct ExcalidrawScene {
    /// Apple Pencil 的 maximumPossibleForce，用來把 force 正規化成 Excalidraw 的 0...1 pressure
    public static let maxForce = 4.166_666_7
    static let customKey = "easynotes"

    public internal(set) var raw: [String: Any]

    public init() {
        raw = [
            "type": "excalidraw",
            "version": 2,
            "source": "easynotes",
            "elements": [[String: Any]](),
            "appState": ["viewBackgroundColor": "#ffffff", "gridSize": NSNull()],
            "files": [String: Any](),
        ]
    }

    public init(data: Data) throws {
        if data.isEmpty { self.init(); return }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict["type"] as? String == "excalidraw"
        else { throw CocoaError(.fileReadCorruptFile) }
        self.init(raw: dict)
    }

    private init(raw: [String: Any]) {
        self.raw = raw
    }

    public var elements: [[String: Any]] {
        raw["elements"] as? [[String: Any]] ?? []
    }

    public func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: 合併

    /// 與 Excalidraw 官方協作相同：依元素 id 取 version 較高者，同 version 取 versionNonce 較小者。
    /// 刪除是墓碑（`isDeleted`），所以只在一邊出現的元素一定是新增的，直接保留。
    /// 順序沿用本地，遠端新增的元素依遠端順序附加在後；`files` 取聯集，`appState` 用本地。
    public static func merge(local: ExcalidrawScene, remote: ExcalidrawScene) -> ExcalidrawScene {
        let remoteByID = Dictionary(remote.elements.compactMap { el in (el["id"] as? String).map { ($0, el) } },
                                    uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [[String: Any]] = local.elements.map { el in
            guard let id = el["id"] as? String else { return el }
            seen.insert(id)
            guard let other = remoteByID[id] else { return el }
            return wins(other, over: el) ? other : el
        }
        result += remote.elements.filter { el in
            guard let id = el["id"] as? String else { return false }
            return !seen.contains(id)
        }
        var merged = local
        // 有 index 就依它排序（相同時依 id），兩台裝置合併出來的順序一致；舊檔案沿用本地順序
        merged.raw["elements"] = SceneEditor.sorted(result.map(Element.init(raw:))).map(\.raw)
        let localFiles = local.raw["files"] as? [String: Any] ?? [:]
        let remoteFiles = remote.raw["files"] as? [String: Any] ?? [:]
        merged.raw["files"] = localFiles.merging(remoteFiles) { mine, _ in mine }
        return merged
    }

    private static func wins(_ a: [String: Any], over b: [String: Any]) -> Bool {
        let va = number(a["version"]) ?? 0, vb = number(b["version"]) ?? 0
        if va != vb { return va > vb }
        return (number(a["versionNonce"]) ?? 0) < (number(b["versionNonce"]) ?? 0)
    }

    // MARK: freedraw ⇄ InkStroke

    public var inkStrokes: [InkStroke] {
        elements.compactMap { el in
            guard el["type"] as? String == "freedraw", el["isDeleted"] as? Bool != true else { return nil }
            return Self.decode(el)
        }
    }

    /// 以新的筆畫清單更新場景：
    /// - 與既有元素相同的筆畫：元素原封不動（version 不變，同步時不產生變更）
    /// - 消失的筆畫：標記 `isDeleted` 並遞增 version（Excalidraw 協作合併依賴墓碑）
    /// - 新筆畫：附加到最上層
    public mutating func replaceInk(with strokes: [InkStroke]) {
        var remaining = strokes
        var result: [[String: Any]] = []
        for el in elements {
            guard el["type"] as? String == "freedraw", el["isDeleted"] as? Bool != true,
                  let existing = Self.decode(el)
            else { result.append(el); continue }
            if let i = remaining.firstIndex(where: { $0.matches(existing) }) {
                remaining.remove(at: i)
                result.append(el)
            } else {
                var tomb = Element(raw: el)
                tomb.isDeleted = true
                tomb.touch()
                result.append(tomb.raw)
            }
        }
        raw["elements"] = result
        // 新筆畫放最上層；有 index 的場景替它們產生 index
        for stroke in remaining { insert(Element(raw: Self.encode(stroke))) }
    }

    static func decode(_ el: [String: Any]) -> InkStroke? {
        guard let originX = number(el["x"]), let originY = number(el["y"]),
              let rawPoints = el["points"] as? [[Any]] else { return nil }
        let custom = (el["customData"] as? [String: Any])?[customKey] as? [String: Any]
        let pressures = (el["pressures"] as? [Any])?.compactMap(number) ?? []
        let forces = (custom?["force"] as? [Any])?.compactMap(number)
        let sizes = (custom?["size"] as? [Any])?.compactMap(number)
        let times = (custom?["t"] as? [Any])?.compactMap(number)
        let azimuths = (custom?["az"] as? [Any])?.compactMap(number)
        let altitudes = (custom?["alt"] as? [Any])?.compactMap(number)
        // excalidraw.com 畫的筆畫沒有點大小：沿用渲染器的 perfect-freehand 寬度（strokeWidth × 4.25），
        // 否則 strokeWidth 1 的筆畫在 PencilKit 只有 1pt，與縮圖、excalidraw.com 不一致
        let widths = sizes == nil ? ElementGeometry.freedrawWidths(Element(raw: el)) : []

        let points = rawPoints.enumerated().compactMap { i, p -> InkStroke.Point? in
            guard p.count >= 2, let dx = number(p[0]), let dy = number(p[1]) else { return nil }
            let force = forces?[safe: i] ?? pressures[safe: i].map { $0 * maxForce } ?? 1
            return InkStroke.Point(
                x: originX + dx, y: originY + dy, force: force,
                size: sizes?[safe: i] ?? widths[safe: i] ?? 2,
                timeOffset: times?[safe: i] ?? Double(i) / 120,
                azimuth: azimuths?[safe: i] ?? 0,
                altitude: altitudes?[safe: i] ?? .pi / 2)
        }
        guard !points.isEmpty else { return nil }
        return InkStroke(
            id: el["id"] as? String,
            ink: custom?["ink"] as? String ?? "com.apple.ink.pen",
            color: el["strokeColor"] as? String ?? "#1e1e1e",
            opacity: (number(el["opacity"]) ?? 100) / 100,
            points: points)
    }

    static func encode(_ stroke: InkStroke) -> [String: Any] {
        let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        let sizes = stroke.points.map(\.size)
        let width = sizes.isEmpty ? 2 : sizes.reduce(0, +) / Double(sizes.count)
        return [
            "type": "freedraw",
            "id": stroke.id ?? randomID(),
            "x": minX, "y": minY,
            "width": (xs.max() ?? 0) - minX, "height": (ys.max() ?? 0) - minY,
            "angle": 0,
            "strokeColor": stroke.color,
            "backgroundColor": "transparent",
            "fillStyle": "solid",
            "strokeWidth": width,
            "strokeStyle": "solid",
            "roughness": 0,
            "opacity": Int((stroke.opacity * 100).rounded()),
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
            "points": stroke.points.map { [$0.x - minX, $0.y - minY] },
            "pressures": stroke.points.map { min(max($0.force / maxForce, 0), 1) },
            "simulatePressure": false,
            "lastCommittedPoint": NSNull(),
            // Excalidraw 會保留 customData；放 PencilKit 專屬資訊讓來回轉換無損
            "customData": [customKey: [
                "ink": stroke.ink,
                "force": stroke.points.map(\.force),
                "size": sizes,
                "t": stroke.points.map(\.timeOffset),
                "az": stroke.points.map(\.azimuth),
                "alt": stroke.points.map(\.altitude),
            ]],
        ]
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    static func randomID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return String((0..<21).map { _ in chars.randomElement()! })
    }
}

public enum InkKind: DocumentKind {
    public static let id = "ink"
    public static let fileExtensions = ["excalidraw"]

    public static func template(title: String) -> Data {
        (try? ExcalidrawScene().data()) ?? Data()
    }

    public static func index(_ data: Data, fileName: String) -> IndexEntry {
        // 白板內的文字元素也納入搜尋
        let elements = ((try? ExcalidrawScene(data: data))?.elements ?? []).filter { $0["isDeleted"] as? Bool != true }
        let texts = elements.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        let links = (try? ExcalidrawScene(data: data))?.noteLinks ?? []
        return IndexEntry(title: (fileName as NSString).deletingPathExtension, plainText: texts.joined(separator: "\n"),
                          links: links, summary: "\(elements.count) 個元素")
    }

    public static func renameLinks(in data: Data, from oldName: String, to newName: String) -> Data? {
        guard var scene = try? ExcalidrawScene(data: data), scene.renameLinks(from: oldName, to: newName) else { return nil }
        return try? scene.data()
    }

    /// 依元素 id + version 合併，不需要 base；任一邊不是合法的 .excalidraw 才交給衝突副本
    public static func merge(base: Data?, local: Data, remote: Data) -> Data? {
        if local == remote { return local }
        guard let l = try? ExcalidrawScene(data: local), let r = try? ExcalidrawScene(data: remote) else { return nil }
        return try? ExcalidrawScene.merge(local: l, remote: r).data()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
