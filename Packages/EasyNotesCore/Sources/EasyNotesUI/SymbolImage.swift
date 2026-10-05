import SwiftUI

/// Draws an SF Symbol as a PNG data URI for WebViews, which have no SF Symbols.
/// Outputs a black monochrome image that the web side uses as a CSS mask, with the color decided by CSS (following light / dark).
@MainActor
public enum SymbolImage {
    private static var cache: [String: Data] = [:]

    public static func png(_ symbol: String, pointSize: CGFloat = 32) -> Data? {
        let key = "\(symbol)@\(pointSize)"
        if let cached = cache[key] { return cached }
        guard let png = render(symbol, pointSize: pointSize) else { return nil }
        cache[key] = png
        return png
    }

    public static func pngDataURI(_ symbol: String, pointSize: CGFloat = 32) -> String? {
        png(symbol, pointSize: pointSize).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    private static func render(_ symbol: String, pointSize: CGFloat) -> Data? {
        #if os(iOS)
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(.black, renderingMode: .alwaysOriginal)
            .pngData()
        #else
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(paletteColors: [.black]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
        #endif
    }
}
