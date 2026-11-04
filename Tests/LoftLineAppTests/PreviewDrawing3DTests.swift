import CADCore
import CAMCore
import Foundation
import SceneKit
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewDrawing3DTests {
    @Test func clickingBackOnTheFirstPointClosesTheShape() {
        var d = Preview3DDrawing()
        #expect(d.click(Vec2(0, 0), tolerance: 0.1) == .added)
        #expect(d.click(Vec2(4, 0), tolerance: 0.1) == .added)
        #expect(d.click(Vec2(4, 3), tolerance: 0.1) == .added)
        let r = d.click(Vec2(0.05, 0.02), tolerance: 0.1)
        #expect(r == .finished(points: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3)], closed: true))
        #expect(d.isEmpty)
        let s = Preview3DDrawing.shape(points: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 3)], closed: true, layerID: UUID())
        #expect(s?.paths.count == 1)
        #expect(s?.paths.first?.isClosed == true)
        #expect(s?.name == "Polygon")
    }

    @Test func clickingTheLastPointAgainFinishesOpen() {
        var d = Preview3DDrawing()
        _ = d.click(Vec2(1, 1), tolerance: 0.1)
        // A stray double-click on the first point does not add a duplicate.
        #expect(d.click(Vec2(1.01, 1), tolerance: 0.1) == .added)
        #expect(d.points.count == 1)
        _ = d.click(Vec2(5, 1), tolerance: 0.1)
        #expect(d.click(Vec2(5, 1.02), tolerance: 0.1) == .finished(points: [Vec2(1, 1), Vec2(5, 1)], closed: false))
        let s = Preview3DDrawing.shape(points: [Vec2(1, 1), Vec2(5, 1)], closed: false, layerID: UUID())
        #expect(s?.paths.first?.isClosed == false)
        #expect(s?.name == "Polyline")
    }

    @Test func pointsSnapToNearbyVectorNodes() {
        var d = Preview3DDrawing()
        _ = d.click(Vec2(2.04, 2.97), tolerance: 0.1, snapTargets: [Vec2(2, 3), Vec2(9, 9)])
        #expect(d.points == [Vec2(2, 3)])
        _ = d.click(Vec2(6, 6), tolerance: 0.1, snapTargets: [Vec2(2, 3)])
        #expect(d.points.last == Vec2(6, 6))
        d.undoLastPoint()
        #expect(d.points == [Vec2(2, 3)])
        #expect(d.finish() == nil) // one point is not a shape
        #expect(d.isEmpty)
    }

    @Test func picksVectorsLikeTheCanvas() {
        let layer = UUID()
        let square = Shape(name: "sq", layerID: layer, paths: [Path(points: [Vec2(0, 0), Vec2(4, 0), Vec2(4, 4), Vec2(0, 4)], closed: true)])
        let line = Shape(name: "ln", layerID: layer, paths: [Path(points: [Vec2(10, 0), Vec2(10, 5)], closed: false)])
        #expect(Preview3DDrawing.pickShape(at: Vec2(10.05, 2), in: [square, line], tolerance: 0.1) == line.id)
        #expect(Preview3DDrawing.pickShape(at: Vec2(2, 2), in: [square, line], tolerance: 0.1) == square.id)
        #expect(Preview3DDrawing.pickShape(at: Vec2(7, 2), in: [square, line], tolerance: 0.1) == nil)
    }

    @Test @MainActor func modelReportsFinishedShapesAndDrawsTheDraft() {
        let model = SimulationPreviewModel()
        let saved = model.showVectors
        defer { model.showVectors = saved }
        var finished: [([Vec2], Bool)] = []
        model.onDrawShape = { finished.append(($0, $1)) }
        model.tool = .draw
        model.handle(Preview3DPick(point: Vec3(1, 1, -0.2), tolerance: 0.1, onStock: true))
        model.handle(Preview3DPick(point: Vec3(3, 1, 0), tolerance: 0.1, onStock: false))
        #expect(model.drawing.points == [Vec2(1, 1), Vec2(3, 1)])
        #expect(model.stockScene.draftLineCount == 1)
        model.finishDrawing()
        #expect(finished.count == 1)
        #expect(finished.first?.0 == [Vec2(1, 1), Vec2(3, 1)])
        #expect(finished.first?.1 == false)
        #expect(model.stockScene.draftLineCount == 0)
        // Leaving draw mode drops an unfinished drawing.
        model.handle(Preview3DPick(point: Vec3(5, 5, 0), tolerance: 0.1, onStock: false))
        model.tool = .none
        #expect(model.drawing.isEmpty)
    }

    @Test @MainActor func modelSelectsWithClicks() {
        let model = SimulationPreviewModel()
        let saved = model.showVectors
        defer { model.showVectors = saved }
        var picked: [(Vec2, Double)] = []
        model.onSelectAt = { picked.append(($0, $1)) }
        model.handle(Preview3DPick(point: Vec3(1, 1, 0), tolerance: 0.1, onStock: true))
        #expect(picked.isEmpty) // no tool: clicks do nothing
        model.tool = .select
        model.handle(Preview3DPick(point: Vec3(2, 3, -0.1), tolerance: 0.2, onStock: true))
        #expect(picked.count == 1)
        #expect(picked.first?.0 == Vec2(2, 3))
    }

    @Test @MainActor func selectedVectorsAreDrawnAndClicksMeetTheMaterialTop() throws {
        let job = JobSetup(width: 10, height: 10, thickness: 0.75)
        let scene = StockScene()
        scene.configure(job: job)
        let v = [Vec2(0, 0), Vec2(5, 5)]
        let g = try #require(StockScene.overlayGeometry(toolpaths: nil, showRapids: false, vectors: [v], selected: [v]))
        #expect(g.elements.first?.primitiveCount == 2)
        // A view ray from above the material at (3, 4) meets the top plane there.
        let near = scene.content.convertPosition(SCNVector3(3, 4, 5), to: nil)
        let far = scene.content.convertPosition(SCNVector3(3, 4, -5), to: nil)
        let p = try #require(scene.materialTopPoint(near: near, far: far))
        #expect(abs(p.x - 3) < 1e-4 && abs(p.y - 4) < 1e-4 && p.z == 0)
        // A ray parallel to the top never meets it.
        let a = scene.content.convertPosition(SCNVector3(0, 0, 1), to: nil)
        let b = scene.content.convertPosition(SCNVector3(5, 0, 1), to: nil)
        #expect(scene.materialTopPoint(near: a, far: b) == nil)
    }
}
