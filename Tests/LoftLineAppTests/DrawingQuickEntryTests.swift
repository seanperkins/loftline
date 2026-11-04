import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingQuickEntryTests {
    let layer = UUID()

    @Test func parsesValues() {
        #expect(QuickEntry.parse("3") == .one(3))
        #expect(QuickEntry.parse("3, -2.5") == .pair(3, -2.5))
        #expect(QuickEntry.parse("5<30") == .polar(length: 5, degrees: 30))
        #expect(QuickEntry.parse("1,2,3") == nil)
        #expect(QuickEntry.parse("abc") == nil)
        #expect(QuickEntry.accepts("4", buffer: ""))
        #expect(!QuickEntry.accepts(",", buffer: ""))
        #expect(QuickEntry.accepts(",", buffer: "4"))
        #expect(!QuickEntry.accepts("r", buffer: "4"))
    }

    @Test func boxAndRadialShapes() throws {
        let r = try #require(QuickEntry.pair(4, 2).shape(for: .rectangle, anchor: Vec2(1, 1), options: DrawingOptions(), layerID: layer))
        #expect(r.bounds().min == Vec2(1, 1) && r.bounds().max == Vec2(5, 3))
        let left = try #require(QuickEntry.pair(4, 2).shape(for: .rectangle, anchor: Vec2(1, 1), direction: Vec2(-1, 1),
                                                           options: DrawingOptions(), layerID: layer))
        #expect(left.bounds().min.x == -3)
        let c = try #require(QuickEntry.one(1.5).shape(for: .circle, anchor: .zero, options: DrawingOptions(), layerID: layer))
        #expect(c.origin == .circle(radius: 1.5))
        #expect(QuickEntry.polar(length: 1, degrees: 0).shape(for: .rectangle, anchor: .zero, options: DrawingOptions(), layerID: layer) == nil)
    }

    @Test func freehandSmoothsAndCloses() throws {
        // Jittery quarter circle: simplified, then smoothed into Béziers through few points.
        let pts = (0...200).map { i -> Vec2 in
            let a = Double(i) / 200 * .pi / 2
            return Vec2(5 * cos(a), 5 * sin(a)) + Vec2(i.isMultiple(of: 2) ? 0.003 : -0.003, 0)
        }
        let s = try #require(DrawingTools.freehand(points: pts, tolerance: 0.02, closeTolerance: 0.1, layerID: layer))
        #expect(!s.paths[0].isClosed)
        #expect(s.paths[0].segments.count < 20)
        #expect(s.paths[0].segments.allSatisfy { if case .cubic = $0 { return true }; return false })
        let loop = (0...100).map { i -> Vec2 in let a = Double(i) / 100 * 2 * .pi; return Vec2(cos(a), sin(a)) }
        #expect(try #require(DrawingTools.freehand(points: loop, tolerance: 0.01, closeTolerance: 0.05, layerID: layer)).paths[0].isClosed)
    }

    @Test func linePoints() {
        #expect(QuickEntry.pair(2, 3).nextPoint(after: nil, cursor: nil) == Vec2(2, 3))
        #expect(QuickEntry.pair(2, 3).nextPoint(after: Vec2(1, 1), cursor: nil) == Vec2(3, 4))
        let p = QuickEntry.polar(length: 2, degrees: 90).nextPoint(after: Vec2(1, 1), cursor: nil)!
        #expect(p.isApproximatelyEqual(to: Vec2(1, 3), tolerance: 1e-12))
        #expect(QuickEntry.one(5).nextPoint(after: .zero, cursor: Vec2(0, -1)) == Vec2(0, -5))
        #expect(QuickEntry.one(5).nextPoint(after: nil, cursor: Vec2(0, -1)) == nil)
    }
}
