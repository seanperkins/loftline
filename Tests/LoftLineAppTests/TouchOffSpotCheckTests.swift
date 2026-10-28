import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The touch plate must lie on solid material: on the stock, off keep-out zones and clamps, and clear of every toolpath of
/// the posted sheet, switched on or off (spec §5). Each failure refuses the export with no program.
@Suite struct TouchOffSpotCheckTests {
    static let probe = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.5, plateSize: 3,
                                       probeFeed: 5, probeTravel: 0.5, controller: .mach4, mach4ZeroMacro: 199)
    static var probing: PostProfile {
        var m = BuiltInMachines.avidPRO6096
        m.toolChangeProbe = probe
        return m.applied(to: BuiltInPosts.avidMach4Inch)
    }

    /// The 24 x 18 in test project (rectangles at (1,1) and (5,1)), two profiles calculated, the spot at `spot`.
    func makeDoc(spot: Vec2 = Vec2(15, 10)) -> (LoftLineDocument, [UUID]) {
        var p = AppTestSupport.project()
        p.document.job.touchOffSpot = spot
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let shapes = doc.document.shapes.map(\.id)
        doc.setSelection([shapes[0]])
        doc.addOperation(.profile)
        doc.setSelection([shapes[1]])
        doc.addOperation(.profile)
        let ids = doc.project.operations.map(\.id)
        doc.calculateNow(ids)
        return (doc, ids)
    }

    func export(_ doc: LoftLineDocument, scope: GCodeExportScope = .all, sheet: SheetToolpaths?? = .none) -> GCodeExportResult {
        let tps = GCodeExporter.toolpaths(scope: scope, operations: doc.outputProject.operations, results: doc.results,
                                          groupByTool: false)
        let s = sheet ?? GCodeExporter.sheetToolpathsIfProbing(project: doc.project, results: doc.results, scope: scope,
                                                               profile: Self.probing)
        return GCodeExporter.export(project: doc.outputProject(for: scope), toolpaths: tps, profile: Self.probing,
                                    jobName: "J", sheetToolpaths: s)
    }

    func expectRefused(_ r: GCodeExportResult, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.text == nil && r.errorMessage != nil, "\(what): \(r.errorMessage ?? "posted")", sourceLocation: sourceLocation)
    }

    @Test func aClearSpotPosts() {
        let (doc, _) = makeDoc()
        let r = export(doc)
        #expect(r.text != nil, "\(r.errorMessage ?? "")")
    }

    @Test func footprintCircumscribesTheDisc() {
        let poly = TouchOffSpotCheck.footprint(spot: Vec2(10, 10), radius: 4.243)
        #expect(poly.count == 32)
        // Every edge's midpoint is at least the radius from the spot.
        for (a, b) in zip(poly, poly.dropFirst() + [poly[0]]) {
            #expect(((a + b) * 0.5).distance(to: Vec2(10, 10)) >= 4.243 - 1e-9)
        }
    }

    @Test func nearAnEdgeIsRefused() {
        // A 3 x 3 in plate touched at a corner reaches 4.243 in; the editor's size is that diagonal.
        let (doc, _) = makeDoc(spot: Vec2(22, 10))
        expectRefused(export(doc), "spot 2 in from the right edge")
    }

    @Test func onAKeepOutZoneIsRefused() {
        let (doc, _) = makeDoc()
        doc.perform("Zone") { $0.document.keepOutZones = [KeepOutZone(name: "Hold-down", outline: [Vec2(16, 9), Vec2(18, 9), Vec2(18, 11), Vec2(16, 11)], height: 0.5)] }
        expectRefused(export(doc), "keep-out zone")
    }

    @Test func onAClampIsRefused() {
        let (doc, _) = makeDoc()
        doc.perform("Clamp") { p in
            var layer = Layer(name: "Clamps", colorHex: "#888888")
            layer.keepOut = LayerKeepOut(height: 1)
            p.document.layers.append(layer)
            p.document.add(AppTestSupport.rect(13, 12, 2, 2, layer: layer.id))
        }
        expectRefused(export(doc), "clamp")
    }

    @Test func overAPocketInAnotherFileIsRefused() {
        // The spot sits over the second rectangle's profile; the first is exported on its own.
        let (doc, ids) = makeDoc(spot: Vec2(6, 4))
        expectRefused(export(doc, scope: .operation(ids[0])), "single operation over another toolpath's cut")
        let files = GCodeBatchExport.plan(mode: .filePerTool, operations: doc.outputProject.operations, results: doc.results,
                                          jobName: "J", profile: Self.probing)
        let sheet = GCodeExporter.sheetToolpathsIfProbing(project: doc.project, results: doc.results, scope: .all, profile: Self.probing)
        for (_, r) in GCodeBatchExport.post(files, project: doc.outputProject, profile: Self.probing, jobName: "J", sheetToolpaths: sheet) {
            expectRefused(r, "file per tool")
        }
    }

    @Test func aSwitchedOffPocketIsStillAPocket() {
        let (doc, ids) = makeDoc(spot: Vec2(6, 4))
        doc.setOperationEnabled(ids[1], false)
        doc.calculateNow(ids)
        // Cut, then switched off, and the rest exported.
        expectRefused(export(doc), "switched-off pocket under the spot")
        // A switched-off pocket exported on its own.
        expectRefused(export(doc, scope: .operation(ids[1])), "switched-off pocket exported alone")
    }

    @Test func failedSheetOperations() {
        let (doc, ids) = makeDoc()
        var results = doc.results
        var failed = results[ids[1]]!
        failed.toolpaths = []; failed.error = "no vectors"
        results[ids[1]] = failed
        guard case .refused = GCodeExporter.sheetToolpaths(project: doc.project, results: results, sheetID: doc.document.currentSheetID) else {
            Issue.record("a switched-on operation that failed was not refused"); return
        }
        var off = doc.project
        var setup = off.operations[1].editableSetup
        setup.isEnabled = false
        off.operations[1] = off.operations[1].with(setup: setup)
        guard case .ready = GCodeExporter.sheetToolpaths(project: off, results: results, sheetID: doc.document.currentSheetID) else {
            Issue.record("a switched-off operation that failed was not skipped"); return
        }
        results.removeValue(forKey: ids[1])
        guard case .refused = GCodeExporter.sheetToolpaths(project: doc.project, results: results, sheetID: doc.document.currentSheetID) else {
            Issue.record("an uncalculated operation was not refused"); return
        }
    }

    @Test func missingOrIncompleteSheetToolpathsRefuse() {
        let (doc, ids) = makeDoc()
        expectRefused(export(doc, sheet: .some(nil)), "no sheet toolpaths with probing")
        expectRefused(export(doc, scope: .operation(ids[0]), sheet: .some(.ready([]))), "sheet lacks the exported toolpaths")
    }

    @Test func calculationTargetsAreKeptApartFromExportedTargets() {
        let (doc, ids) = makeDoc()
        #expect(GCodeExporter.calculationTargets(project: doc.project, exported: [ids[0]], scope: .operation(ids[0]),
                                                 profile: Self.probing) == [ids[0], ids[1]])
        #expect(GCodeExporter.calculationTargets(project: doc.project, exported: [ids[0]], scope: .operation(ids[0]),
                                                 profile: BuiltInPosts.avidMach4Inch) == [ids[0]])
        // The missing-from-the-program errors still judge only what is exported.
        var results = doc.results
        results.removeValue(forKey: ids[1])
        #expect(GCodeExporter.missingOperationIssues([doc.operation(ids[0])!], results: results).isEmpty)
    }

    @Test func theSheetIsTheOnePosted() {
        let lib = AppTestSupport.library()
        let p = AppTestSupport.project()
        let doc = LoftLineDocument(project: p, toolLibrary: lib)
        let onA = p.document.shapes[0].id, onB = p.document.shapes[1].id
        doc.addSheet()   // sheet B is shown
        let layerB = doc.currentSheetLayers[0].id
        doc.perform("x") { $0.moveShapes([onB], toLayer: layerB) }
        let opA = OperationFactory.make(kind: .profile, project: doc.project, library: doc.mergedLibrary, shapeIDs: [onA])!
        let opB = OperationFactory.make(kind: .profile, project: doc.project, library: doc.mergedLibrary, shapeIDs: [onB])!
        doc.perform("ops") { $0.operations = [opA, opB] }
        // While B is shown, a single toolpath of A is posted with A's sheet, and the reverse.
        #expect(GCodeExporter.postedSheetID(project: doc.project, scope: .operation(opA.id)) == doc.project.sheetID(of: opA))
        #expect(GCodeExporter.postedSheetID(project: doc.project, scope: .operation(opA.id)) != doc.document.currentSheetID)
        #expect(GCodeExporter.sheetOperations(project: doc.project, sheetID: doc.project.sheetID(of: opB)).map(\.id) == [opB.id])
    }

    @Test func tiledWithProbingIsRefusedForEveryTile() {
        let (doc, _) = makeDoc()
        let settings = TiledExport.defaultSettings(profile: Self.probing, units: .inch)
        let files = TiledExport.files(project: doc.outputProject, results: doc.results, profile: Self.probing,
                                      groupByTool: false, settings: settings)
        #expect(!files.isEmpty)
        for f in files { expectRefused(f.result, "tile \(f.tile.number)") }
    }
}
