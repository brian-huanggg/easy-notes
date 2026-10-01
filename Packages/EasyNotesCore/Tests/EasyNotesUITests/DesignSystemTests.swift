import Foundation
import SwiftUI
import Testing
@testable import EasyNotesUI

struct DesignSystemTests {
    @Test func tokenNamesAreUnique() {
        let names = (Palette.all + KindTint.presets.flatMap { [$0.base, $0.soft] }).map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func hexParsing() {
        let opaque = RGBA(hex: "#2C6BE8")
        #expect(opaque.a == 1)
        #expect(opaque.css == "rgb(44, 107, 232)")
        let translucent = RGBA(hex: "#00000055")
        #expect(translucent.css == "rgba(0, 0, 0, 0.333)")
    }

    @Test func cssHasEveryTokenInBothSchemes() {
        let css = ThemeCSS.stylesheet(extra: [KindTint.violet.base])
        for token in Palette.all + [KindTint.violet.base] {
            #expect(css.components(separatedBy: "--\(token.name):").count == 3, "\(token.name)")
        }
        #expect(css.contains("--bg-canvas: rgb(255, 255, 255);"))
        #expect(css.contains("--bg-canvas: rgb(31, 31, 30);"))
        #expect(css.contains("PingFang TC"))
    }

    @Test func resolvesBySchemeFromEnvironment() {
        var env = EnvironmentValues()
        env.colorScheme = .dark
        #expect(Palette.textPrimary.resolve(in: env) == RGBA(hex: "#F2F1ED").resolved)
        env.colorScheme = .light
        #expect(Palette.textPrimary.resolve(in: env) == RGBA(hex: "#1D1C1A").resolved)
    }

    /// `EASYNOTES_SNAPSHOT_DIR=… swift test` 時把一覽頁輸出成 PNG，與 Pen 設計稿並排比對
    @MainActor @Test func gallerySnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["EASYNOTES_SNAPSHOT_DIR"] else { return }
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: DesignSystemGallery()
                .environment(\.colorScheme, scheme)
                .frame(width: 1440))
            renderer.scale = 1
            #if os(macOS)
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(filePath: dir).appending(path: "gallery-\(scheme == .dark ? "dark" : "light").png"))
            #endif
        }
    }
}
