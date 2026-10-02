import EasyNotesUI
import ImageIO
import SwiftUI

/// 白板的列表縮圖與嵌入預覽：`SceneRenderer` 在背景畫成 PNG（白色背景透明），跟著預覽快取依 hash 存成 `<hash>.png`。
/// `lines` 放前幾個文字元素，給沒有圖的情況與之後的搜尋摘要用。
struct BoardPreview: DocumentPreviewProvider {
    /// v2：加入 PNG 縮圖
    var version: Int { 2 }
    static let maxPixelSize = 1600
    static let maxLines = 8

    func makePreview(_ data: Data) -> DocumentPreview {
        guard let scene = try? ExcalidrawScene(data: data) else { return DocumentPreview() }
        let renderer = SceneRenderer(scene: scene, transparentDefaultBackground: true)
        let lines = renderer.elements.filter { $0.type == .text }.prefix(Self.maxLines)
            .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        return DocumentPreview(lines: Array(lines), image: renderer.pngData(maxPixelSize: Self.maxPixelSize))
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView {
        if let image = preview.image {
            AnyView(BoardThumbnail(png: image, padding: 12 * scale))
        } else {
            AnyView(ThumbBoard(tint: .violet, scale: scale))
        }
    }
}

/// 依顯示大小在背景解碼 PNG（不解碼完整的 1600px 圖）；深色模式反相並轉回色相，與 Excalidraw 的深色主題相同
struct BoardThumbnail: View {
    let png: Data
    let padding: CGFloat
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .modifier(DarkInvert(enabled: colorScheme == .dark))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: TaskKey(png: png.count, size: geo.size, scale: displayScale)) {
                let target = Int((max(geo.size.width, geo.size.height) * displayScale).rounded(.up))
                let png = png
                image = await Task.detached(priority: .utility) { Self.decode(png, maxPixels: target) }.value
            }
        }
        .padding(padding)
    }

    private struct TaskKey: Hashable {
        var png: Int
        var size: CGSize
        var scale: CGFloat
    }

    nonisolated static func decode(_ png: Data, maxPixels: Int) -> CGImage? {
        guard maxPixels > 0, let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// CSS 的 `invert(93%) hue-rotate(180deg)`：黑線變淺、彩色維持原本的色相
struct DarkInvert: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.colorInvert().hueRotation(.degrees(180)).brightness(-0.04)
        } else {
            content
        }
    }
}
