import Foundation

/// A platform-independent ink stroke. Conversions between PencilKit and Excalidraw freedraw both go through it.
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

    /// The Excalidraw element id; nil for a new stroke from PencilKit (PKStroke has no stable id)
    public var id: String?
    /// The rawValue of PKInk.InkType, for example "com.apple.ink.pen"
    public var ink: String
    /// sRGB, format "#rrggbb"
    public var color: String
    public var opacity: Double
    public var points: [Point]

    public init(id: String? = nil, ink: String, color: String, opacity: Double = 1, points: [Point]) {
        self.id = id; self.ink = ink; self.color = color; self.opacity = opacity; self.points = points
    }

    /// PencilKit stores coordinates as Float, so round trips have tiny errors and comparisons need a tolerance
    public func matches(_ other: InkStroke, tolerance: Double = 1e-3) -> Bool {
        guard ink == other.ink, color == other.color, points.count == other.points.count else { return false }
        return zip(points, other.points).allSatisfy { a, b in
            abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance && abs(a.force - b.force) < tolerance
        }
    }
}

/// A `.excalidraw` scene. Kept as raw JSON dictionaries; non-freedraw elements and unknown fields are written back untouched, ensuring format compatibility.
public struct ExcalidrawScene {
    /// Apple Pencil's maximumPossibleForce, used to normalize force to Excalidraw's 0...1 pressure
    public static let maxForce = 4.166_666_7
    static let customKey = "easynotes"

    public var raw: [String: Any]

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

    // MARK: Merge

    /// The same as Excalidraw's official collaboration: per element id take the higher version, and with equal versions the smaller versionNonce.
    /// Deletion is a tombstone (`isDeleted`), so an element that appears on one side only is certainly new and is kept directly.
    /// Order follows local; elements newly added remotely are appended after in remote order; `files` takes the union and `appState` uses local.
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
        // With an index, sort by it (ties by id) so two devices merge to the same order; older files keep local order
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

    /// Updates the scene with a new list of strokes:
    /// - A stroke identical to an existing element: the element is untouched (version unchanged, so sync produces no change)
    /// - A vanished stroke: marked `isDeleted` with version incremented (Excalidraw collaboration merge relies on tombstones)
    /// - A new stroke: appended on top
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
        // New strokes go on top; a scene with an index generates indexes for them
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
        // Strokes drawn on excalidraw.com have no point sizes: keep the renderer's perfect-freehand width (strokeWidth × 4.25),
        // otherwise a strokeWidth 1 stroke would be only 1 pt in PencilKit, inconsistent with thumbnails and excalidraw.com
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
            // Excalidraw keeps customData; PencilKit-specific information goes there so round trips are lossless
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
