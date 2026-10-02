import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ExcalidrawScene {
    /// 內嵌圖片的最長邊（像素）
    public static let maxImagePixels = 2048

    /// 插入圖片：ImageIO 縮到最長邊 2048px、轉 JPEG（有透明度的圖保留 PNG，避免透明處變黑），
    /// 以 `dataURL` 寫入 `files`。`fileId` 由內容 hash 決定，同一張圖不會重複內嵌。
    /// 元素顯示尺寸不超過 `maxDisplay`（點）。回傳元素 id；資料不是圖片回傳 nil。
    @discardableResult
    public mutating func insertImage(_ data: Data, at origin: CGPoint, maxDisplay: Double = 400) -> String? {
        guard let encoded = Self.downscale(data) else { return nil }
        let fileId = SHA256.hash(data: encoded.data).map { String(format: "%02x", $0) }.joined().prefix(40).description
        var files = raw["files"] as? [String: Any] ?? [:]
        if files[fileId] == nil {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            files[fileId] = [
                "id": fileId,
                "mimeType": encoded.mimeType,
                "dataURL": "data:\(encoded.mimeType);base64,\(encoded.data.base64EncodedString())",
                "created": now,
                "lastRetrieved": now,
            ]
            raw["files"] = files
        }
        let scale = min(1, maxDisplay / Double(max(encoded.width, encoded.height)))
        let el = Element.image(fileId: fileId, x: origin.x, y: origin.y,
                               width: (Double(encoded.width) * scale).rounded(),
                               height: (Double(encoded.height) * scale).rounded())
        insert(el)
        return el.id
    }

    /// 解出 `files[fileId].dataURL` 的圖片資料
    public func imageData(fileId: String) -> Data? {
        guard let file = (raw["files"] as? [String: Any])?[fileId] as? [String: Any],
              let url = file["dataURL"] as? String, let comma = url.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    struct EncodedImage {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
    }

    static func downscale(_ data: Data) -> EncodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // 套用 EXIF 方向
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // 縮圖 API 不會放大，但原圖小於上限時也要確認取得的是完整尺寸
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }

        let type: UTType = hasAlpha ? .png : .jpeg
        if !hasAlpha, let flat = flatten(image) { image = flat }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, image, hasAlpha ? nil : props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return EncodedImage(data: out as Data, mimeType: hasAlpha ? "image/png" : "image/jpeg",
                            width: image.width, height: image.height)
    }

    /// 轉成 sRGB 不含 alpha 的點陣，JPEG 編碼器對 CMYK、灰階等來源比較穩
    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
