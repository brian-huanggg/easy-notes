import EasyNotesCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns image bytes from the pasteboard, the Bridge or the photo library into a temporary file that
/// `DocumentSession.importAttachment` can copy into `Attachments/`.
enum ImageImport {
    /// The Bridge and the photo picker hand over arbitrary bytes: refuse anything absurdly large before decoding
    static let maxBytes = 40 * 1024 * 1024

    /// PNG, JPEG and GIF are kept as they are (GIF stays animated); anything else, such as HEIC from the photo library,
    /// is re-encoded as JPEG so every platform and the WebView can show it. Returns nil if the data is not an image.
    static func normalized(_ data: Data) -> (data: Data, ext: String)? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }
        switch UTType(identifier) {
        case UTType.png: return (data, "png")
        case UTType.jpeg: return (data, "jpg")
        case UTType.gif: return (data, "gif")
        default:
            let output = NSMutableData()
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            // Keep the orientation: CGImage pixels are not rotated, so carry the EXIF orientation over
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            if let orientation = properties?[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return (output as Data, "jpg")
        }
    }

    /// Writes the image to a fresh temporary folder and returns the file and a cleanup closure; nil if it is not an image
    static func stage(_ data: Data) -> (url: URL, cleanup: () -> Void)? {
        guard let image = normalized(data) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = (L("貼上的圖片-\(stamp).png") as NSString).deletingPathExtension + "." + image.ext
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try image.data.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }
}
