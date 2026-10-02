import EasyNotesCore
import ExcalidrawKit
import Foundation

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
                          links: links, summary: L("\(elements.count) 個元素"))
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
