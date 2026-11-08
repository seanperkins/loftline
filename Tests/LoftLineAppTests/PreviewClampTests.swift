import CADCore
import Foundation
import SceneKit
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Clamps and screws stand on the stock in the 3D preview at their real height (issue #134).
@Suite struct PreviewClampTests {
    let square = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(0, 1)]

    @Test @MainActor func aClampIsABlockFromTheMaterialTopToItsHeight() throws {
        var job = JobSetup()
        job.thickness = 0.75
        let item = ClampItem(name: "Clamps 1", loops: [square], height: 1.5, layerID: nil)
        let node = try #require(StockScene.clampNodes([item], job: job).first)
        let shape = try #require(node.geometry as? SCNShape)
        #expect(shape.extrusionDepth == 1.5)
        // From the geometry's own bounds, not the placement arithmetic: bottom on the top (z = 0), top at 1.5.
        let (lo, hi) = node.boundingBox
        #expect(abs(Double(lo.z + node.position.z)) < 1e-6)
        #expect(abs(Double(hi.z + node.position.z) - 1.5) < 1e-6)
        #expect(node.name == "Clamps 1")
    }

    @Test @MainActor func aFlushScrewIsAThinSlabOnTheTop() throws {
        var job = JobSetup()
        job.thickness = 0.75
        let item = ClampItem(name: "Screw", loops: [square], height: 0, layerID: nil)
        let node = try #require(StockScene.clampNodes([item], job: job).first)
        let depth = try #require((node.geometry as? SCNShape)?.extrusionDepth)
        #expect(depth > 0 && depth < 0.05)
        #expect(abs(Double(node.position.z) - Double(depth) / 2) < 1e-9)
    }

    @Test @MainActor func theSceneShowsAndClearsClamps() {
        let scene = StockScene()
        scene.setClamps([ClampItem(name: "A", loops: [square], height: 1, layerID: nil),
                         ClampItem(name: "B", loops: [square], height: 2, layerID: nil)])
        #expect(scene.clampCount == 2)
        scene.setClamps([])
        #expect(scene.clampCount == 0)
    }
}
