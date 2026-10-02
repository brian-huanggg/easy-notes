import CoreGraphics
import Testing
@testable import KindWhiteboard

struct CanvasRegionTests {
    @Test func coversContentWithMarginOnStepBoundaries() {
        let region = CanvasRegion(covering: CGRect(x: -350, y: 120, width: 800, height: 400))
        #expect(region.rect.contains(CGRect(x: -350 - 6_000, y: 120 - 6_000, width: 800 + 12_000, height: 400 + 12_000)))
        for v in [region.rect.minX, region.rect.minY, region.rect.maxX, region.rect.maxY] {
            #expect(v.truncatingRemainder(dividingBy: 1_000) == 0)
        }
        let empty = CanvasRegion(covering: nil)
        #expect(empty.rect.contains(CGPoint(x: 0, y: 0)))
    }

    @Test func roundTripsCoordinates() {
        let region = CanvasRegion(covering: CGRect(x: -2_500, y: -10, width: 100, height: 100))
        let p = CGPoint(x: -2_499.25, y: 37.5)
        #expect(region.toScene(region.toContent(p)) == p)
        #expect(region.toContent(region.origin) == .zero)
    }

    @Test func growsOnlyNearEdges() throws {
        let region = CanvasRegion(covering: CGRect(x: 0, y: 0, width: 100, height: 100))
        // 中間：不需要擴大
        #expect(region.expanded(toShow: CGRect(x: 0, y: 0, width: 1_000, height: 800)) == nil)
        // 靠近左邊：往左擴大，origin 變小，原本的範圍仍在裡面
        let near = CGRect(x: region.rect.minX + 1_000, y: 0, width: 1_000, height: 800)
        let grown = try #require(region.expanded(toShow: near))
        #expect(grown.origin.x < region.origin.x)
        #expect(grown.rect.contains(region.rect))
        #expect(grown.rect.insetBy(dx: CanvasRegion.margin / 2, dy: CanvasRegion.margin / 2).contains(near))
    }

    @Test func includesFarAwayContent() throws {
        let region = CanvasRegion(covering: nil)
        #expect(region.expanded(toInclude: CGRect(x: 10, y: 10, width: 5, height: 5)) == nil)
        let far = CGRect(x: 50_000, y: -40_000, width: 10, height: 10)
        #expect(try #require(region.expanded(toInclude: far)).rect.contains(far))
    }
}
