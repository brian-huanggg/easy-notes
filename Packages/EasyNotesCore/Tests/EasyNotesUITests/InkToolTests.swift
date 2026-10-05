import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import EasyNotesUI

struct InkStateTests {
    @Test func specFollowsToolAndKind() {
        var state = InkState()
        #expect(state.spec == .ink(inkType: "com.apple.ink.pen", color: "#1e1e1e", widthScale: 1))
        state.penKind = .ballpoint
        state.setWidthLevel(2, for: .pen)
        #expect(state.spec == .ink(inkType: "com.apple.ink.monoline", color: "#1e1e1e", widthScale: 2))
        state.select(.highlighter)
        #expect(state.spec == .ink(inkType: "com.apple.ink.marker", color: "#ffd43b", widthScale: 1))
        state.select(.eraser)
        #expect(state.spec == .eraser(partial: false, widthScale: 1))
        state.eraserKind = .partial
        state.setWidthLevel(0, for: .eraser)
        #expect(state.spec == .eraser(partial: true, widthScale: 0.5))
        state.select(.lasso)
        #expect(state.spec == .lasso)
    }

    @Test func widthLevelIsClamped() {
        var state = InkState()
        state.setWidthLevel(9, for: .highlighter)
        #expect(state.widthLevel(for: .highlighter) == 2)
        state.setWidthLevel(-1, for: .pen)
        #expect(state.widthLevel(for: .pen) == 0)
    }

    @Test func colorsArePerTool() {
        var state = InkState()
        state.setColor("#e03131", for: .pen)
        #expect(state.color(for: .pen) == "#e03131")
        #expect(state.color(for: .highlighter) == "#ffd43b")
    }

    @Test func addColorAppendsSelectsAndCaps() {
        var state = InkState()
        state.addColor("#ABCDEF", for: .pen)
        #expect(state.customColors(for: .pen) == ["#abcdef"])
        #expect(state.penColor == "#abcdef")
        #expect(state.customColors(for: .highlighter).isEmpty)
        // Default colors are not added twice, only selected
        state.addColor("#1971c2", for: .pen)
        #expect(state.customColors(for: .pen) == ["#abcdef"])
        #expect(state.penColor == "#1971c2")
        for i in 0..<6 { state.addColor(String(format: "#0000%02x", i), for: .pen) }
        #expect(state.customColors(for: .pen).count == InkState.maxCustomColors)
        #expect(state.customColors(for: .pen).last == "#000005")
        #expect(!state.customColors(for: .pen).contains("#abcdef"))
    }

    /// The color picker sends values continuously while dragging: replaces the one added last time instead of adding endlessly
    @Test func addColorReplacingLast() {
        var state = InkState()
        state.addColor("#111111", for: .highlighter)
        state.addColor("#222222", for: .highlighter, replacingLast: true)
        state.addColor("#333333", for: .highlighter, replacingLast: true)
        #expect(state.customColors(for: .highlighter) == ["#333333"])
        #expect(state.highlighterColor == "#333333")
        // The current selection is not the one added last time (the user picked a preset instead): not replaced
        state.setColor("#69db7c", for: .highlighter)
        state.addColor("#444444", for: .highlighter, replacingLast: true)
        #expect(state.customColors(for: .highlighter) == ["#333333", "#444444"])
    }

    @Test func removeCurrentColorFallsBackToFirstPreset() {
        var state = InkState()
        state.addColor("#abcdef", for: .pen)
        state.removeColor("#abcdef", for: .pen)
        #expect(state.customColors(for: .pen).isEmpty)
        #expect(state.penColor == InkState.penPresets[0])
    }

    @Test func pencilTapSwitchesEraserAndPrevious() {
        var state = InkState()
        state.select(.highlighter)
        state.pencilTap(.switchEraser)
        #expect(state.tool == .eraser)
        state.pencilTap(.switchEraser)
        #expect(state.tool == .highlighter)
        state.pencilTap(.switchPrevious)
        #expect(state.tool == .eraser)
        state.pencilTap(.switchPrevious)
        #expect(state.tool == .highlighter)
        let toggles = state.pencilTap(.toggleOptions)
        #expect(toggles)
        #expect(state.tool == .highlighter)
    }

    @Test func pencilTapFromEraserWithoutHistoryGoesToPen() {
        var state = InkState()
        state.select(.eraser) // previous = pen
        state.select(.eraser)
        state.pencilTap(.switchEraser)
        #expect(state.tool == .pen)
    }

    @MainActor @Test func settingsPersistAndToggleOptions() throws {
        let defaults = try #require(UserDefaults(suiteName: "InkStateTests-\(UUID().uuidString)"))
        let settings = InkSettings(defaults: defaults)
        settings.choose(.highlighter, alreadyInking: false)
        settings.state.setColor("#74c0fc", for: .highlighter)
        #expect(settings.showsOptions)
        settings.choose(.highlighter, alreadyInking: true)
        #expect(!settings.showsOptions)
        settings.choose(.pen, alreadyInking: true)
        #expect(settings.showsOptions)

        let reloaded = InkSettings(defaults: defaults)
        #expect(reloaded.state.tool == .pen)
        #expect(reloaded.state.highlighterColor == "#74c0fc")
    }

    @Test func colorHexRoundTrip() {
        #expect(InkColor.hex(Color(inkHex: "#1971c2")) == "#1971c2")
        #expect(InkColor.isLight("#ffd43b"))
        #expect(!InkColor.isLight("#1e1e1e"))
    }
}

struct StraightLineTests {
    @Test func snapsNearHorizontalVerticalAndDiagonal() {
        let o = CGPoint.zero
        let h = StraightLine.snapped(from: o, to: CGPoint(x: 100, y: 3)) // ≈ 1.7°
        #expect(abs(h.y) < 1e-9)
        #expect(abs(h.x - hypot(100, 3)) < 1e-9)
        let v = StraightLine.snapped(from: o, to: CGPoint(x: -2, y: -80))
        #expect(abs(v.x) < 1e-9)
        let d = StraightLine.snapped(from: o, to: CGPoint(x: 50, y: 52))
        #expect(abs(d.x - d.y) < 1e-9)
        // 10° does not snap
        let free = CGPoint(x: 100, y: 100 * tan(10 * CGFloat.pi / 180))
        #expect(StraightLine.snapped(from: o, to: free) == free)
    }

    @Test func samplesIncludeEndsWithinSpacing() {
        let pts = StraightLine.samples(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), spacing: 2)
        #expect(pts.first == CGPoint(x: 0, y: 0))
        #expect(pts.last == CGPoint(x: 10, y: 0))
        #expect(pts.count == 6)
        #expect(StraightLine.samples(from: .zero, to: .zero, spacing: 2).count == 2)
    }

    @Test func holdNeedsLengthAndStillness() {
        var d = HoldDetector()
        d.begin(at: .zero, time: 0)
        // Tap-and-hold: not long enough
        #expect(!d.isHolding(at: 1))
        for i in 1...10 { d.move(to: CGPoint(x: Double(i) * 3, y: 0), time: Double(i) * 0.01) }
        #expect(d.length >= StraightLine.minimumLength)
        #expect(!d.isHolding(at: 0.3))
        // A small wobble does not restart the timer
        let jitterRestarts = d.move(to: CGPoint(x: 31, y: 1), time: 0.4)
        #expect(!jitterRestarts)
        #expect(d.isHolding(at: 0.6))
        // Moving beyond the tolerance: restarts the timer
        let moveRestarts = d.move(to: CGPoint(x: 40, y: 0), time: 0.65)
        #expect(moveRestarts)
        #expect(!d.isHolding(at: 1.0))
        #expect(d.isHolding(at: 1.15))
    }
}
