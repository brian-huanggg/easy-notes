import CoreGraphics
import Testing
@testable import KindWhiteboard

/// 4c：拖曳到邊緣自動捲動的速度
struct AutoscrollTests {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func middleDoesNotScroll() {
        #expect(EdgeAutoscroll.velocity(for: CGPoint(x: 400, y: 300), in: bounds) == .zero)
        #expect(EdgeAutoscroll.velocity(for: CGPoint(x: 33, y: 567), in: bounds) == .zero) // 剛好在範圍外
    }

    @Test func speedGrowsTowardEdgeAndCapsOutside() {
        let near = EdgeAutoscroll.velocity(for: CGPoint(x: 790, y: 300), in: bounds)
        let edge = EdgeAutoscroll.velocity(for: CGPoint(x: 800, y: 300), in: bounds)
        let outside = EdgeAutoscroll.velocity(for: CGPoint(x: 1200, y: 300), in: bounds)
        #expect(near.dx > 0 && near.dx < edge.dx)
        #expect(edge.dx == EdgeAutoscroll.maxSpeed)
        #expect(outside.dx == EdgeAutoscroll.maxSpeed)
        #expect(near.dy == 0)
    }

    @Test func directionsAndCorners() {
        let topLeft = EdgeAutoscroll.velocity(for: CGPoint(x: -5, y: 2), in: bounds)
        #expect(topLeft.dx == -EdgeAutoscroll.maxSpeed)
        #expect(topLeft.dy < 0)
        let bottom = EdgeAutoscroll.velocity(for: CGPoint(x: 400, y: 590), in: bounds)
        #expect(bottom.dx == 0 && bottom.dy > 0)
    }

    @Test func tinyViewNeverScrolls() {
        #expect(EdgeAutoscroll.velocity(for: .zero, in: CGRect(x: 0, y: 0, width: 50, height: 50)) == .zero)
    }
}
