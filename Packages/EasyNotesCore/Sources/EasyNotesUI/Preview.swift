import Foundation
import SwiftUI

/// Data of a list card thumbnail. Produced by plugins in the background from file content and cached by content hash, so it holds only serializable values.
/// `image` does not go into JSON: the cache stores it as a `.png` of the same name and the JSON records only whether there is an image.
public struct DocumentPreview: Codable, Hashable, Sendable {
    public var title: String?
    /// The first few lines after the title (syntax removed)
    public var lines: [String]
    /// A thumbnail PNG drawn by a graphical plugin (whiteboard); also used by `![[x]]` embeds (`embed://`)
    public var image: Data?

    public init(title: String? = nil, lines: [String] = [], image: Data? = nil) {
        self.title = title
        self.lines = lines
        self.image = image
    }

    private enum CodingKeys: String, CodingKey {
        case title, lines, hasImage
    }

    /// Whether the cached JSON has a matching PNG (`image` itself is read and written separately by `PreviewCache`)
    public private(set) var hasImage = false

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        hasImage = try c.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(lines, forKey: .lines)
        if image != nil || hasImage { try c.encode(true, forKey: .hasImage) }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.title == b.title && a.lines == b.lines && a.image == b.image
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(lines)
        hasher.combine(image)
    }
}

/// A thumbnail a plugin registers with `addPreview(for:_:)`. Rendered natively, no WebView.
/// `makePreview` is called on a background thread and its result is cached; `view` draws the cached data as a thumbnail on the main thread.
public protocol DocumentPreviewProvider: Sendable {
    /// Increment when the way of producing changes, so old caches are no longer used
    var version: Int { get }
    func makePreview(_ data: Data) -> DocumentPreview
    /// `scale`: 1 for Desktop cards, about 0.7 for Mobile Pin Cards
    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView
}

public extension DocumentPreviewProvider {
    var version: Int { 1 }
}

/// Preview cache: memory → `<directory>/<kind>-v<version>/<hash>.json` (+ `<hash>.png`) → regenerate.
/// An unchanged file (same hash) is not recomputed; the cache folder may be deleted entirely and later regenerates identical results.
/// Memory keeps only the JSON part; PNGs have a separate size-limited cache, so scrolling a list past thousands of files does not keep every image in memory.
public actor PreviewCache {
    private let directory: URL
    private var memory: [String: DocumentPreview] = [:]
    private var order: [String] = []
    private let memoryLimit: Int
    private let images = NSCache<NSString, NSData>()

    /// Usually `<vault>/.easynotes/cache/preview` (cache does not take part in sync)
    public init(directory: URL, memoryLimit: Int = 2000, imageMemoryLimit: Int = 32 << 20) {
        self.directory = directory
        self.memoryLimit = memoryLimit
        images.totalCostLimit = imageMemoryLimit
    }

    /// `load` is called only when the cache misses (reads the file)
    public func preview(kindID: String, hash: String, provider: any DocumentPreviewProvider,
                        load: @Sendable () throws -> Data) -> DocumentPreview? {
        let folder = "\(kindID)-v\(provider.version)"
        let key = "\(folder)/\(hash)"
        let url = directory.appending(path: folder, directoryHint: .isDirectory).appending(path: "\(hash).json")
        let pngURL = url.deletingPathExtension().appendingPathExtension("png")

        if let cached = memory[key] ?? readJSON(url, key: key) {
            guard cached.hasImage else { return cached }
            if let image = image(key: key, url: pngURL) {
                var full = cached
                full.image = image
                return full
            }
            // The PNG was deleted: regenerate downward
        }
        guard let content = try? load() else { return nil }
        let preview = provider.makePreview(content)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write the PNG before the JSON: when the JSON says there is an image it is always there
        if let image = preview.image {
            try? image.write(to: pngURL, options: .atomic)
            images.setObject(image as NSData, forKey: key as NSString, cost: image.count)
        }
        if let json = try? JSONEncoder().encode(preview) {
            try? json.write(to: url, options: .atomic)
            if let stored = try? JSONDecoder().decode(DocumentPreview.self, from: json) { remember(stored, for: key) }
        }
        return preview
    }

    /// Deletes every cached preview whose content hash is not in `live` (memory and disk, all kinds). A thumbnail is a picture of the file,
    /// so after a permanent delete it must not outlive it; pruning by "what is still alive" also catches thumbnails of files that were soft-deleted
    /// earlier, whose hash nobody remembers. Anything restored or still needed simply regenerates the next time it is shown.
    public func prune(keeping live: Set<String>) {
        func hash(of key: String) -> String { String(key.split(separator: "/").last ?? "") }
        for key in memory.keys where !live.contains(hash(of: key)) {
            memory[key] = nil
            images.removeObject(forKey: key as NSString)
        }
        order.removeAll { memory[$0] == nil }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !live.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func readJSON(_ url: URL, key: String) -> DocumentPreview? {
        guard let data = try? Data(contentsOf: url), let cached = try? JSONDecoder().decode(DocumentPreview.self, from: data)
        else { return nil }
        remember(cached, for: key)
        return cached
    }

    private func image(key: String, url: URL) -> Data? {
        if let cached = images.object(forKey: key as NSString) { return cached as Data }
        guard let data = try? Data(contentsOf: url) else { return nil }
        images.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    private func remember(_ preview: DocumentPreview, for key: String) {
        if memory[key] == nil { order.append(key) }
        memory[key] = preview
        if order.count > memoryLimit {
            memory[order.removeFirst()] = nil
        }
    }
}
