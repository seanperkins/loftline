import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct ViewportTests {
    @Test func roundTripsCoordinates() {
        let vp = CanvasViewport(scale: 12.5, offset: Vec2(30, -7))
        let p = Vec2(3.25, -1.5)
        #expect(vp.toDocument(vp.toView(p)).isApproximatelyEqual(to: p, tolerance: 1e-12))
    }

    @Test func zoomKeepsAnchorFixed() {
        var vp = CanvasViewport()
        let anchor = Vec2(200, 150)
        let before = vp.toDocument(anchor)
        vp.zoom(by: 2.5, about: anchor)
        #expect(vp.toDocument(anchor).isApproximatelyEqual(to: before, tolerance: 1e-9))
        #expect(vp.scale == 50)
    }

    @Test func zoomIsClamped() {
        var vp = CanvasViewport()
        vp.zoom(by: 1e-9, about: .zero)
        #expect(vp.scale == CanvasViewport.minScale)
    }

    @Test func fitCentresRect() {
        var vp = CanvasViewport()
        let r = Rect2(x: 0, y: 0, width: 24, height: 18)
        vp.fit(r, viewSize: Vec2(1000, 800), margin: 40)
        #expect(vp.toView(r.center).isApproximatelyEqual(to: Vec2(500, 400), tolerance: 1e-9))
        #expect(abs(vp.scale - min(920.0 / 24, 720.0 / 18)) < 1e-9)
    }
}

@Suite struct RulerTickTests {
    @Test func majorStepKeepsTicksApart() {
        #expect(RulerTicks.majorStep(scale: 20, units: .inch) == 6)
        #expect(RulerTicks.majorStep(scale: 100, units: .inch) == 1)
        #expect(RulerTicks.majorStep(scale: 2, units: .millimeter) == 50)
    }

    @Test func valuesAreMultiplesWithinRange() {
        #expect(RulerTicks.values(from: -0.1, to: 2.1, step: 0.5) == [0, 0.5, 1, 1.5, 2])
        #expect(RulerTicks.values(from: 1, to: 0, step: 1).isEmpty)
    }

    @Test func labelsTrimZeros() {
        #expect(RulerTicks.label(1.5) == "1.5")
        #expect(RulerTicks.label(12) == "12")
        #expect(RulerTicks.label(0.125) == "0.125")
        #expect(RulerTicks.label(-0.00001) == "0")
    }
}

@Suite struct HitTestingTests {
    let layer = UUID()
    let shapes: [FlatShape]

    init() {
        shapes = [FlatShape(AppTestSupport.rect(0, 0, 10, 10, layer: layer), tolerance: 0.01),
                  FlatShape(AppTestSupport.rect(2, 2, 2, 2, layer: layer), tolerance: 0.01)]
    }

    @Test func picksNearestOutline() {
        #expect(HitTesting.pick(at: Vec2(0.05, 5), in: shapes, tolerance: 0.1) == shapes[0].shape.id)
    }

    @Test func picksSmallestContainingShapeWhenNotOnOutline() {
        #expect(HitTesting.pick(at: Vec2(3, 3), in: shapes, tolerance: 0.1) == shapes[1].shape.id)
        #expect(HitTesting.pick(at: Vec2(7, 7), in: shapes, tolerance: 0.1) == shapes[0].shape.id)
        #expect(HitTesting.pick(at: Vec2(20, 20), in: shapes, tolerance: 0.1) == nil)
    }

    @Test func windowSelectionNeedsFullContainment() {
        let r = Rect2(x: 1, y: 1, width: 4, height: 4)
        #expect(HitTesting.select(in: r, candidates: shapes, crossing: false) == [shapes[1].shape.id])
    }

    @Test func crossingSelectionTakesTouchedShapes() {
        let r = Rect2(x: -1, y: 3, width: 4, height: 0.5) // crosses the big square's left edge and the small one
        #expect(Set(HitTesting.select(in: r, candidates: shapes, crossing: true)) == Set(shapes.map(\.shape.id)))
        let inner = Rect2(x: 6, y: 6, width: 1, height: 1) // inside the big square, touching nothing
        #expect(HitTesting.select(in: inner, candidates: shapes, crossing: true).isEmpty)
    }

    @Test func gridSnapping() {
        #expect(Snapping.snap(Vec2(1.13, -0.37), grid: 0.25) == Vec2(1.25, -0.25))
        #expect(Snapping.snap(Vec2(1.13, 2), grid: 0) == Vec2(1.13, 2))
    }
}

@Suite struct DrawingToolsTests {
    let layer = UUID()

    @Test func rectangleFromAnyDragDirection() {
        let s = DrawingTools.shape(for: .rectangle, from: Vec2(4, 3), to: Vec2(1, 1), options: DrawingOptions(), layerID: layer)!
        let b = s.bounds()
        #expect(b.min == Vec2(1, 1) && b.max == Vec2(4, 3))
        #expect(s.isClosed)
    }

    @Test func constrainedRectangleIsSquare() {
        var o = DrawingOptions()
        o.constrain = true
        let b = DrawingTools.shape(for: .rectangle, from: .zero, to: Vec2(3, 1), options: o, layerID: layer)!.bounds()
        #expect(abs(b.width - 3) < 1e-9 && abs(b.height - 3) < 1e-9)
    }

    @Test func circleUsesDragAsRadius() {
        let s = DrawingTools.shape(for: .circle, from: Vec2(5, 5), to: Vec2(8, 9), options: DrawingOptions(), layerID: layer)!
        #expect(s.origin == .circle(radius: 5))
        #expect(abs(s.bounds().width - 10) < 1e-6)
    }

    @Test func zeroSizeDragMakesNothing() {
        #expect(DrawingTools.shape(for: .rectangle, from: .zero, to: Vec2(0, 3), options: DrawingOptions(), layerID: layer) == nil)
    }

    @Test func polylineClosesNearStart() {
        let pts = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(0.01, 0.01)]
        let s = DrawingTools.polyline(points: pts, closeTolerance: 0.1, layerID: layer)!
        #expect(s.isClosed)
        #expect(s.paths[0].segments.count == 2) // closing edge is implicit
        let open = DrawingTools.polyline(points: [Vec2(0, 0), Vec2(2, 0), Vec2(2, 0)], closeTolerance: 0.1, layerID: layer)!
        #expect(!open.isClosed && open.paths[0].segments.count == 1)
    }

    @Test func curvePassesThroughPoints() {
        let s = DrawingTools.smoothCurve(points: [Vec2(0, 0), Vec2(1, 1), Vec2(2, 0)], closeTolerance: 0, layerID: layer)!
        #expect(s.paths[0].segments.count == 2)
        #expect(s.paths[0].segments[0].end == Vec2(1, 1))
        #expect(s.paths[0].end == Vec2(2, 0))
    }
}

@Suite struct DesignCommandTests {
    @Test func alignLeft() {
        var p = AppTestSupport.project()
        DesignCommands.align(Set(p.document.shapes.map(\.id)), mode: .left, in: &p)
        #expect(p.document.shapes.allSatisfy { abs($0.bounds().min.x - 1) < 1e-9 })
    }

    @Test func centreOnMaterial() {
        var p = AppTestSupport.project()
        let ids = Set(p.document.shapes.map(\.id))
        DesignCommands.align(ids, mode: .materialCenter, in: &p)
        #expect(p.bounds(of: ids).center.isApproximatelyEqual(to: Vec2(12, 9), tolerance: 1e-9))
    }

    @Test func distributeEvenly() {
        var p = AppTestSupport.project()
        p.document.add(AppTestSupport.rect(20, 1, 2, 1, layer: p.document.defaultLayerID))
        DesignCommands.distribute(Set(p.document.shapes.map(\.id)), horizontally: true, in: &p)
        let xs = p.document.shapes.map { $0.bounds().center.x }.sorted()
        #expect(abs((xs[1] - xs[0]) - (xs[2] - xs[1])) < 1e-9)
    }

    @Test func fitResizesToTarget() {
        var p = AppTestSupport.project()
        let id = p.document.shapes[0].id
        TransformCommands.fit([id], to: Rect2(x: 0, y: 0, width: 4, height: 3), keepAspect: false, in: &p)
        let b = p.document.shape(id: id)!.bounds()
        #expect(b.min.isApproximatelyEqual(to: .zero, tolerance: 1e-9))
        #expect(abs(b.width - 4) < 1e-9 && abs(b.height - 3) < 1e-9)
    }

    @Test func mirrorFlipsAboutTheShapesOwnCentre() throws {
        var p = AppTestSupport.project()
        // An asymmetric shape: a right triangle with its right angle at the lower left.
        let tri = Shape(name: "T", layerID: p.document.defaultLayerID,
                        paths: [Path(points: [Vec2(1, 1), Vec2(4, 1), Vec2(1, 3)], closed: true)])
        p.document.add(tri)
        let before = tri.bounds()
        TransformCommands.mirror([tri.id], horizontally: true, in: &p)
        let after = try #require(p.document.shape(id: tri.id))
        #expect(before.min.isApproximatelyEqual(to: after.bounds().min, tolerance: 1e-9))
        // The right angle is now at the lower right and the winding has flipped.
        let pts = after.paths[0].flattened()
        #expect(pts.contains { $0.isApproximatelyEqual(to: Vec2(4, 1), tolerance: 1e-9) })
        #expect(pts.contains { $0.isApproximatelyEqual(to: Vec2(4, 3), tolerance: 1e-9) })
        #expect(after.paths[0].signedArea() * tri.paths[0].signedArea() < 0)
    }

    @Test func unionReplacesInputs() {
        var p = AppTestSupport.project()
        p.document.add(AppTestSupport.rect(2, 1.5, 4, 1, layer: p.document.defaultLayerID)) // bridges both
        let id = DesignCommands.boolean(.union, ids: p.document.shapes.map(\.id), in: &p)
        #expect(id != nil)
        #expect(p.document.shapes.count == 1)
    }

    @Test func groupAndUngroup() {
        var p = AppTestSupport.project()
        let g = DesignCommands.combine(p.document.shapes.map(\.id), in: &p)!
        #expect(p.document.shapes.count == 1 && p.document.shape(id: g)!.paths.count == 2)
        let parts = DesignCommands.explode([g], in: &p)
        #expect(parts.count == 2 && p.document.shapes.count == 2)
    }
}
