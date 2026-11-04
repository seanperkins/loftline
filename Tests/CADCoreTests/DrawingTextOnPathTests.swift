import Foundation
import Testing
@testable import CADCore

@Suite struct DrawingTextOnPathTests {
    let outliner = TextOutliner()

    @Test func glyphsAdvanceLeftToRight() throws {
        let g = try outliner.glyphs(for: "AB C", fontName: testFont, size: 1)
        #expect(g.count == 4)
        #expect(g[0].x == 0 && g[1].x > g[0].x && g[3].x > g[2].x)
        #expect(g[2].paths.isEmpty)  // the space has no outline
    }

    @Test func straightGuideMatchesNormalLayout() throws {
        let g = try outliner.glyphs(for: "HI", fontName: testFont, size: 1)
        let line = Path(points: [Vec2(0, 0), Vec2(10, 0)], closed: false)
        let placed = TextOnPath.layout(g, along: line, placement: .start, startDistance: 1)
        let plain = try outliner.outlines(for: "HI", fontName: testFont, size: 1, origin: Vec2(1, 0))
        let a = Rect2(points: placed.flatMap { $0.flattened() }), b = Rect2(points: plain.flatMap { $0.flattened() })
        #expect(a.min.isApproximatelyEqual(to: b.min, tolerance: 1e-6) && a.max.isApproximatelyEqual(to: b.max, tolerance: 1e-6))
    }

    @Test func textOnCircleTopReadsAndStaysOutside() throws {
        let g = try outliner.glyphs(for: "TOP", fontName: testFont, size: 0.5)
        // Clockwise circle from the bottom: its half-way point is the top.
        let c = Vec2(0, 0), r = 5.0
        let circle = Path(start: Vec2(0, -r), segments: [.arc(to: Vec2(0, r), center: c, clockwise: true),
                                                         .arc(to: Vec2(0, -r), center: c, clockwise: true)], isClosed: true)
        let placed = TextOnPath.layout(g, along: circle, placement: .center)
        let pts = placed.flatMap { $0.flattened() }
        #expect(pts.allSatisfy { $0.y > 0 })
        #expect(pts.allSatisfy { $0.distance(to: c) >= r - 0.03 })  // round letters overshoot the baseline a little
        #expect(abs(Rect2(points: pts).center.x) < 0.2)
    }
}
