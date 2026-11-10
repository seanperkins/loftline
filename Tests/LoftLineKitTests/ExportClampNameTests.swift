import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// An export error names the clamp the way the job sheet, the canvas and the 3D preview do (issue #138): two unnamed shapes on
/// the Clamps layer are "Clamp 1" and "Clamp 2", not both "Clamps".
@Suite struct ExportClampNameTests {
    /// The 24 x 18 test project (2 x 1 rectangles at (1,1) and (5,1)), a Clamps layer, and a profile round both rectangles.
    func project() throws -> (LoftLineProject, UUID, [Toolpath]) {
        var p = AppTestSupport.project()
        let clamps = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 1))
        p.document.layers.append(clamps)
        let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: ToolLibrary.seeded.tools[0].id,
                                                                             shapeIDs: p.document.shapes.map(\.id))))
        p.upsertOperation(op)
        let tps = try op.generate(in: CAMContext(document: p.document, tools: .seeded))
        return (p, clamps.id, tps)
    }

    func errors(_ p: LoftLineProject, _ tps: [Toolpath]) -> [String] {
        GCodeExporter.export(project: p, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T",
                             expected: .notChecked(because: "test")).issues.filter { $0.severity == .error }.map(\.message)
    }

    @Test func aClampOnALayerIsNamedWithItsNumber() throws {
        var (p, clamps, tps) = try project()
        p.document.add(AppTestSupport.rect(20, 14, 2, 2, layer: clamps).named(""))        // Clamp 1, clear of the cut
        p.document.add(AppTestSupport.rect(4.5, 1.2, 0.8, 0.5, layer: clamps).named(""))  // Clamp 2, over the second rectangle's left edge
        let e = errors(p, tps)
        #expect(e.contains { $0.contains("'Clamp 2'") }, "\(e)")
        #expect(!e.contains { $0.contains("'Clamps'") || $0.contains("'Clamp 1'") }, "\(e)")
    }

    @Test func aKeepOutZoneSharingTheNameIsNumberedAsTheSheetNumbersIt() throws {
        var (p, clamps, tps) = try project()
        p.document.add(AppTestSupport.rect(20, 14, 2, 2, layer: clamps).named(""))   // "Clamp 1" on the sheet
        p.document.keepOutZones = [KeepOutZone(name: "Clamp", outline: [Vec2(4.5, 1.2), Vec2(5.3, 1.2), Vec2(5.3, 1.7), Vec2(4.5, 1.7)],
                                               height: 1)]
        #expect(ClampList.items(in: p.document).map(\.name) == ["Clamp 1", "Clamp 2"])
        let e = errors(p, tps)
        #expect(e.contains { $0.contains("keep-out zone \"Clamp 2\"") }, "\(e)")
    }

    @Test func aClampWithANameOfItsOwnKeepsIt() throws {
        var (p, clamps, tps) = try project()
        p.document.add(AppTestSupport.rect(4.5, 1.2, 0.8, 0.5, layer: clamps).named("Vise jaw"))
        let e = errors(p, tps)
        #expect(e.contains { $0.contains("'Vise jaw'") }, "\(e)")
    }

    @Test func theTouchPlateCheckNamesTheClampWithItsNumber() throws {
        var (p, clamps, _) = try project()
        p.document.job.touchOffSpot = Vec2(15, 10)
        p.document.add(AppTestSupport.rect(20, 14, 2, 2, layer: clamps).named(""))
        p.document.add(AppTestSupport.rect(14, 9, 2, 2, layer: clamps).named(""))   // under the plate
        let probe = ToolChangeProbe.defaults(for: BuiltInMachines.avidPRO6096)
        let problem = try #require(TouchOffSpotCheck.problem(project: p, sheet: [], probe: probe, postUnits: .inch))
        #expect(problem.contains("\"Clamp 2\""), "\(problem)")
    }

    /// Review finding: each zone gets its own name in the same pass, so a zone that doesn't count (two points) in the middle
    /// can't shift the names onto the wrong clamps. Geometry and ids are the zone's own.
    @Test func numberedNamesEachZoneInPlace() throws {
        var (p, clamps, _) = try project()
        p.document.add(AppTestSupport.rect(20, 14, 2, 2, layer: clamps).named("Vise"))
        let a = KeepOutZone(name: "Vise", outline: [Vec2(1, 1), Vec2(2, 1), Vec2(2, 2)], height: 0)
        let line = KeepOutZone(name: "Line", outline: [Vec2(0, 0), Vec2(1, 1)], height: 0)
        let b = KeepOutZone(name: "Vise", outline: [Vec2(8, 8), Vec2(9, 8), Vec2(9, 9)], height: 0)
        p.document.keepOutZones = [a, line, b]
        let n = ClampList.numbered(in: p.document)
        #expect(n.layerZones.map(\.name) == ["Vise 1"])
        let zones = try #require(n.keepOutZones)
        #expect(zones.map(\.name) == ["Vise 2", "Line", "Vise 3"])
        #expect(zones.map(\.id) == [a.id, line.id, b.id])
        #expect(zones.map(\.outline) == [a.outline, line.outline, b.outline])
        #expect(n.layerZones.map(\.loops) == Fixtures.zones(in: p.document).map(\.loops))
    }

    /// The touch-plate check looks at Keep-Out Zones before layer clamps, as it did before #138: under both, it names the zone.
    @Test func theTouchPlateCheckStillNamesAKeepOutZoneFirst() throws {
        var (p, clamps, _) = try project()
        p.document.job.touchOffSpot = Vec2(15, 10)
        p.document.add(AppTestSupport.rect(14, 9, 2, 2, layer: clamps).named(""))
        p.document.keepOutZones = [KeepOutZone(name: "Hold-down", outline: [Vec2(14.5, 9.5), Vec2(15.5, 9.5), Vec2(15.5, 10.5), Vec2(14.5, 10.5)],
                                               height: 0)]
        let probe = ToolChangeProbe.defaults(for: BuiltInMachines.avidPRO6096)
        let problem = try #require(TouchOffSpotCheck.problem(project: p, sheet: [], probe: probe, postUnits: .inch))
        #expect(problem.contains("\"Hold-down\""), "\(problem)")
    }
}

private extension Shape {
    func named(_ n: String) -> Shape { var s = self; s.name = n; return s }
}
