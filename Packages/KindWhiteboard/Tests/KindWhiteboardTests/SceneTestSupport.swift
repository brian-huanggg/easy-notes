import CoreGraphics
import EasyNotesCore
import EasyNotesUI
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ExcalidrawKit
@testable import KindWhiteboard

enum Fixture {
    static func data(_ name: String = "excalidraw-export") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "excalidraw", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 兩個形狀 + 一支水平箭頭：R(100,100,200×100) —→ E(500,100,200×100)，箭頭在 y=150
    static func boundScene() -> (scene: ExcalidrawScene, rect: String, ellipse: String, arrow: String) {
        var scene = ExcalidrawScene()
        let r = Element.rectangle(x: 100, y: 100, width: 200, height: 100)
        let e = Element.ellipse(x: 500, y: 100, width: 200, height: 100)
        let a = Element.arrow(from: CGPoint(x: 305, y: 150), to: CGPoint(x: 495, y: 150))
        scene.insert(r); scene.insert(e); scene.insert(a)
        scene.bind(arrow: a.id, .start, to: r.id)
        scene.bind(arrow: a.id, .end, to: e.id)
        return (scene, r.id, e.id, a.id)
    }

    /// `boundElements` 與箭頭的綁定兩邊一致；文字的 `containerId` 與容器的 `boundElements` 一致
    static func bindingProblems(_ scene: ExcalidrawScene) -> [String] {
        let live = scene.liveElements
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var problems: [String] = []
        for el in live {
            if el.type == .arrow {
                for end in [ArrowEnd.start, .end] {
                    guard let b = el.binding(end) else { continue }
                    guard let shape = byID[b.elementId] else { problems.append("\(el.id) 綁到不存在的 \(b.elementId)"); continue }
                    if !shape.boundElements.contains(where: { $0.id == el.id && $0.type == "arrow" }) {
                        problems.append("\(shape.id) 的 boundElements 缺少箭頭 \(el.id)")
                    }
                }
            }
            if let c = el.containerId, byID[c]?.boundElements.contains(where: { $0.id == el.id && $0.type == "text" }) != true {
                problems.append("\(c) 的 boundElements 缺少文字 \(el.id)")
            }
            for bound in el.boundElements {
                guard let other = byID[bound.id] else { problems.append("\(el.id) 的 boundElements 指向不存在的 \(bound.id)"); continue }
                if bound.type == "arrow", other.binding(.start)?.elementId != el.id, other.binding(.end)?.elementId != el.id {
                    problems.append("箭頭 \(other.id) 沒有綁到 \(el.id)")
                }
                if bound.type == "text", other.containerId != el.id { problems.append("文字 \(other.id) 的 containerId 不是 \(el.id)") }
            }
        }
        return problems
    }

    /// 點到矩形（實心）的距離
    static func distance(from p: CGPoint, to r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func pngData(width: Int, height: Int, alpha: Bool = false) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }
}

/// 測試用的 Vault：寫入只記錄、不碰檔案
@MainActor
final class FakeSession: DocumentSession {
    var files: [String: Data] = [:]
    private(set) var writes: [(path: String, data: Data)] = []
    let vault: VaultFS
    var index: VaultIndex? { nil }
    var resourceReader: @Sendable (String) async -> Data? { { _ in nil } }
    /// 筆記卡片的預覽（路徑 → 預覽）
    nonisolated(unsafe) var previews: [String: DocumentPreview] = [:]
    var previewReader: @Sendable (String) async -> DocumentPreview? { { [unowned self] in self.previews[$0] } }

    init() {
        vault = VaultFS(root: FileManager.default.temporaryDirectory, kinds: try! KindRegistry([InkKind.self]))
    }

    func readData(_ path: String) -> Data { files[path] ?? Data() }
    func write(_ data: Data, to path: String) { files[path] = data; writes.append((path, data)) }
    func openLink(_ target: String) {}
    func search(_ query: String) {}
    func modified(_ path: String) -> Date? { nil }
    func importAttachment(_ url: URL) async -> String? { nil }
    func open(_ path: String, line: Int?) {}
    func metaChanged() {}
}
