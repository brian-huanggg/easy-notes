#if canImport(PencilKit)
import CoreGraphics
import PencilKit

#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

extension InkStroke {
    public init(_ stroke: PKStroke) {
        let t = stroke.transform
        let points = stroke.path.map { p -> Point in
            let loc = p.location.applying(t)
            return Point(
                x: Double(loc.x), y: Double(loc.y), force: Double(p.force), size: Double(p.size.width),
                timeOffset: p.timeOffset, azimuth: Double(p.azimuth), altitude: Double(p.altitude),
                opacity: Double(p.opacity))
        }
        let (hex, alpha) = Self.hex(stroke.ink.color.cgColor)
        self.init(ink: stroke.ink.inkType.rawValue, color: hex, opacity: alpha, points: points)
    }

    public var pkStroke: PKStroke {
        let points = points.map { p in
            PKStrokePoint(
                location: CGPoint(x: p.x, y: p.y), timeOffset: p.timeOffset,
                size: CGSize(width: p.size, height: p.size), opacity: CGFloat(p.opacity),
                force: CGFloat(p.force), azimuth: CGFloat(p.azimuth), altitude: CGFloat(p.altitude))
        }
        let inkType = PKInk.InkType(rawValue: ink) ?? .pen
        let ink = PKInk(inkType, color: Self.color(hex: color, alpha: opacity))
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    static func hex(_ color: CGColor) -> (String, Double) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let c = srgb?.components ?? [0, 0, 0, 1]
        let rgb = c.count >= 3 ? Array(c.prefix(3)) : [c[0], c[0], c[0]]
        let hex = rgb.map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
        return ("#" + hex, Double(c.last ?? 1))
    }

    static func color(hex: String, alpha: Double) -> PlatformColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits.prefix(6), radix: 16) ?? 0x1e1e1e
        return PlatformColor(
            red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255, alpha: CGFloat(alpha))
    }
}

extension ExcalidrawScene {
    public var drawing: PKDrawing {
        PKDrawing(strokes: inkStrokes.map(\.pkStroke))
    }

    public mutating func update(from drawing: PKDrawing) {
        replaceInk(with: drawing.strokes.map(InkStroke.init))
    }
}
#endif
