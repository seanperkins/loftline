import AppKit
import CADCore
import CAMCore
import Foundation
import Metal
import SceneKit
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewOverlay3DTests {
    let job = JobSetup(width: 10, height: 10, thickness: 0.75)

    private func slot() -> Toolpath {
        let coords = MachineCoordinates(job: job)
        let tool = Tool(name: "EM", kind: .endMill, number: 1, diameter: 0.25, stepdown: 0.1, stepover: 0.1,
                        feedRate: 60, plungeRate: 20)
        return Toolpath(name: "slot", kind: .profile, tool: tool, moves: [
            .rapid(to: coords.machineAtSafeZ(Vec2(1, 1))),
            .linear(to: coords.machine(Vec2(1, 1), depth: 0.2), feed: 18),
            .linear(to: coords.machine(Vec2(7, 1), depth: 0.2), feed: 60),
            .rapid(to: coords.machineAtSafeZ(Vec2(7, 1))),
            .rapid(to: coords.machineAtSafeZ(Vec2(2, 2))),
        ])
    }

    @Test @MainActor func geometryHasOneLinePerSegment() throws {
        let lines = ToolpathLines3D(toolpaths: [slot()], coords: MachineCoordinates(job: job))
        #expect(lines.segmentCount == 4) // 2 feeds, 2 rapids
        let all = try #require(StockScene.overlayGeometry(toolpaths: lines, showRapids: true, vectors: []))
        #expect(all.elements.first?.primitiveCount == 4)
        #expect(all.elements.first?.primitiveType == .line)
        let feeds = try #require(StockScene.overlayGeometry(toolpaths: lines, showRapids: false, vectors: []))
        #expect(feeds.elements.first?.primitiveCount == 2)
        // A closed square (5 points) adds 4 lines.
        let square = [Vec2(0, 0), Vec2(2, 0), Vec2(2, 2), Vec2(0, 2), Vec2(0, 0)]
        let both = try #require(StockScene.overlayGeometry(toolpaths: lines, showRapids: false, vectors: [square]))
        #expect(both.elements.first?.primitiveCount == 6)
        #expect(StockScene.overlayGeometry(toolpaths: nil, showRapids: true, vectors: []) == nil)
    }

    /// Top orthographic render with toolpath lines. Set LOFTLINE_RENDER_DIR to keep the PNG.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    @MainActor func rendersTopOrthographicWithLines() throws {
        let scene = StockScene()
        scene.configure(job: job)
        scene.updateStock(HeightfieldMesh(heightfield: Heightfield(width: 10, height: 10, cellSize: 0.1),
                                          thickness: job.thickness))
        scene.setView(.top)
        scene.isOrthographic = true
        scene.showOverlay(toolpaths: ToolpathLines3D(toolpaths: [slot()], coords: MachineCoordinates(job: job)),
                          showRapids: true, vectors: [[Vec2(1, 5), Vec2(9, 5)]])
        let image = try #require(PreviewImageExport.render(scene, size: CGSize(width: 400, height: 400)))
        let data = try #require(PreviewImageExport.pngData(image))
        let rep = try #require(NSBitmapImageRep(data: data))
        // The slot runs along material y = 1 from x = 1 to 7: in a top view framed on the 10 x 10
        // stock it crosses the lower part of the image, in a colour unlike the plain stock.
        let stock = rep.colorAt(x: 200, y: 120)
        let onSlot = (0..<400).contains { y in
            guard let c = rep.colorAt(x: 160, y: y), let s = stock else { return false }
            return abs(c.blueComponent - s.blueComponent) > 0.3
        }
        #expect(onSlot)
        if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("preview-top-lines.png"))
        }
    }

    @Test @MainActor func modelTogglesLinesInTheScene() {
        let model = SimulationPreviewModel()
        let saved = (model.showToolpathLines, model.showRapidLines, model.showVectors)
        defer {
            model.showToolpathLines = saved.0; model.showRapidLines = saved.1; model.showVectors = saved.2
        }
        model.showToolpathLines = true
        model.showRapidLines = true
        model.showVectors = false
        model.configure(job: job, toolpaths: [slot()], rapidRate: 180, units: .inch)
        #expect(model.stockScene.overlayLineCount == 4)
        model.showRapidLines = false
        #expect(model.stockScene.overlayLineCount == 2)
        model.showVectors = true
        model.setVectors([[Vec2(0, 0), Vec2(5, 5)]])
        #expect(model.stockScene.overlayLineCount == 3)
        model.showToolpathLines = false
        #expect(model.stockScene.overlayLineCount == 1)
        model.showVectors = false
        #expect(model.stockScene.overlayLineCount == 0)
    }

    // MARK: One owner for "show vectors" (docs/implicit-state-machines.md #20)

    @Test @MainActor func drawModeShowsVectorsWithoutChangingThePreference() {
        let model = SimulationPreviewModel()
        let saved = model.showVectors
        defer { model.showVectors = saved; model.tool = .none }
        model.showToolpathLines = true
        model.showVectors = false
        model.configure(job: job, toolpaths: [], rapidRate: 180, units: .inch)
        model.setVectors([[Vec2(0, 0), Vec2(5, 5)]])
        #expect(model.stockScene.overlayLineCount == 0)
        model.tool = .draw
        #expect(model.stockScene.overlayLineCount == 1)            // shown while drawing...
        #expect(model.showVectors == false)                         // ...without changing the saved preference
        #expect(UserDefaults.standard.bool(forKey: SimulationPreviewModel.showVectorsKey) == false)
        model.tool = .none
        #expect(model.stockScene.overlayLineCount == 0)
    }

    @Test @MainActor func bothWindowsReadOneFlag() {
        let a = SimulationPreviewModel(), b = SimulationPreviewModel()
        let saved = a.showVectors
        defer { a.showVectors = saved }
        a.showVectors = true
        #expect(b.showVectors == true)
        b.showVectors = false
        #expect(a.showVectors == false)
    }

    @Test @MainActor func measureEndsWhenTheToolbarIsDisabled() {
        let model = SimulationPreviewModel()
        model.tool = .measure
        model.toolpathsChanged(isEmpty: false)
        #expect(model.tool == .measure)
        model.toolpathsChanged(isEmpty: true)   // the toolbar is disabled with no toolpaths
        #expect(model.tool == .none)
    }
}
