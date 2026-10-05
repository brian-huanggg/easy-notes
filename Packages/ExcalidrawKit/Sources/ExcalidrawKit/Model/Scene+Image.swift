import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ExcalidrawScene {
    /// The longest side (pixels) of an embedded image
    public static let maxImagePixels = 2048

    /// Inserts an image: ImageIO scales to a longest side of 2048 px and converts to JPEG (images with transparency stay PNG so transparent areas do not turn black),
    /// written into `files` as `dataURL`. `fileId` is decided by the content hash, so one image is never embedded twice.
    /// The element's display size does not exceed `maxDisplay` (points). Returns the element id; returns nil when the data is not an image.
    @discardableResult
    public mutating func insertImage(_ data: Data, at origin: CGPoint, maxDisplay: Double = 400) -> String? {
        guard let encoded = Self.downscale(data) else { return nil }
        return insertImage(encoded, maxDisplay: maxDisplay) { _ in origin }
    }

    /// Inserts an already thumbnailed image (the editor runs `downscale` in the background), centered at `center`
    @discardableResult
    public mutating func insertImage(_ encoded: EncodedImage, center: CGPoint, maxDisplay: Double) -> String {
        insertImage(encoded, maxDisplay: maxDisplay) { CGPoint(x: center.x - $0.width / 2, y: center.y - $0.height / 2) }
    }

    private mutating func insertImage(_ encoded: EncodedImage, maxDisplay: Double,
                                      origin: (CGSize) -> CGPoint) -> String {
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
        let size = CGSize(width: (Double(encoded.width) * scale).rounded(), height: (Double(encoded.height) * scale).rounded())
        let o = origin(size)
        let el = Element.image(fileId: fileId, x: o.x, y: o.y, width: size.width, height: size.height)
        insert(el)
        return el.id
    }

    /// Decodes the image data of `files[fileId].dataURL`
    public func imageData(fileId: String) -> Data? {
        guard let file = (raw["files"] as? [String: Any])?[fileId] as? [String: Any],
              let url = file["dataURL"] as? String, let comma = url.firstIndex(of: ",")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    public struct EncodedImage: Sendable {
        public var data: Data
        public var mimeType: String
        public var width: Int
        public var height: Int
    }

    public static func downscale(_ data: Data) -> EncodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // Apply the EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // The thumbnail API never enlarges, but even when the original is under the cap we must confirm the full size was obtained
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

    /// Converts to an sRGB bitmap without alpha; the JPEG encoder is steadier with CMYK, grayscale and similar sources
    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
