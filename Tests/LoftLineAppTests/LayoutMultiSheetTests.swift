import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct LayoutMultiSheetTests {
    /// 12x12 material and one 5x5 plate with a profile toolpath; nesting 9 copies needs 3 sheets.
    func overflowed() -> (LoftLineProject, NestingReport) {
        var doc = Document(job: JobSetup(width: 12, height: 12, thickness: 0.5))
        let plate = AppTestSupport.rect(20, 0, 5, 5, layer: doc.defaultLayerID)
        doc.add(plate)
        var p = LoftLineProject(document: doc)
        p.operations = [OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [plate.id])!]
        var o = NestingOptions.defaults(for: .inch)
        o.precision = .draft
        o.quantity = 9
        o.overflowSheets = true
        let r = NestingCommands.nest([plate.id], options: o, in: &p)
        return (p, r)
    }

    @Test func overflowCreatesParkedSheets() {
        let (p, r) = overflowed()
        #expect(r.placed == 9)
        #expect(r.unplaced == 0)
        #expect(r.sheets == 3)
        #expect(NestSheets.numbers(in: p.document) == [1, 2, 3])
        #expect(p.operations[0].setup.shapeIDs.count == 9)
        // Sheet 1 parts are on the material; the others are not, and are not validated as stray.
        let onMaterial = NestSheets.activeDocument(p.document).shapes
        #expect(onMaterial.count == 4)
        #expect(LayoutChecks.design(p.document, ignoredLayers: p.layoutIgnoredLayers).isEmpty)
    }

    @Test func onlyTheSheetOnTheMaterialIsMachined() {
        let (p, _) = overflowed()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let id = p.operations[0].id
        doc.calculateNow([id])
        let loops1 = doc.results[id]?.toolpaths.first?.xyBounds
        #expect(loops1 != nil)
        #expect((loops1?.max.x ?? 99) < 12.5)
        doc.showSheetOnMaterial(3)
        #expect(NestSheets.activeSheet(in: doc.document) == 3)
        #expect(doc.isStale(id))
        doc.calculateNow([id])
        #expect(doc.results[id]?.error == nil)
        #expect((doc.results[id]?.toolpaths.first?.xyBounds.max.x ?? 99) < 12.5)
    }

    @Test func toolpathsOnlyOnParkedSheetsExplainWhy() {
        var (p, _) = overflowed()
        let parked = NestSheets.shapes(onSheet: 2, in: p.document).map(\.id)
        let op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [parked[0]])!
        p.operations = [op]
        let r = ToolpathCalculator.calculate(op, project: p, library: .seeded, designRevision: 0, rapidRate: 100)
        #expect(r.error?.contains("not on the material") == true)
    }

    @Test func jobSheetHasOneSectionPerSheet() {
        let (p, _) = overflowed()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let js = doc.makeJobSheet(settings: TimeEstimateSettings())
        #expect(js.sheets.count == 3)
        #expect(js.sheets[0].title.contains("on the material"))
        #expect(js.sheets.map(\.partNames.count).reduce(0, +) == 9)
        // Every sheet's shapes are drawn in the material frame.
        for s in js.sheets {
            for shape in s.shapes { #expect(shape.bounds().max.x <= 12 + 1e-6) }
        }
    }

    // MARK: Layers keep their sheet and side (docs/implicit-state-machines.md #13)

    /// A two-sheet project, switched to its second sheet ("B").
    func onSheetB() -> (LoftLineProject, UUID) {
        var p = AppTestSupport.project()
        let b = p.document.addSheet(name: "B", job: JobSetup(width: 10, height: 10, thickness: 0.5), layerName: "B",
                                    colorHex: "#336699")
        p.document.switchToSheet(b)
        return (p, b)
    }

    @Test func aLayerAddedOnSheet2ShowsOnSheet2() {
        var (p, b) = onSheetB()
        let id = p.addLayer()
        #expect(p.document.sheetID(ofLayer: id) == b)
    }

    @Test func importOnSheet2LandsOnSheet2() throws {
        // Including a file layer named like a layer of the first sheet: that one is not reused.
        var (p, b) = onSheetB()
        let first = Layer(name: "Cut")
        p.document.layers.append(first)
        let dxf = ["0", "SECTION", "2", "ENTITIES", "0", "LINE", "8", "Cut", "10", "1", "20", "1", "30", "0", "11", "3",
                   "21", "1", "31", "0", "0", "ENDSEC", "0", "EOF"].joined(separator: "\n") + "\n"
        let out = try ImportService.importFile(data: Data(dxf.utf8), fileName: "part.dxf", into: &p)
        let shape = try #require(out.shapeIDs.first.flatMap { p.document.shape(id: $0) })
        #expect(shape.layerID != first.id)
        #expect(p.document.sheetID(ofLayer: shape.layerID) == b)
    }

    @Test func deletingTheOnlyTopLayerKeepsVectorsOnTop() throws {
        // Two-sided: the top side's only layer is deleted; its vectors stay on the top side (a new layer), never moved
        // to the bottom side's layer.
        var p = AppTestSupport.project()
        p.document.job.twoSided = TwoSidedSetup()
        let top = p.document.layers[0].id
        var bottom = Layer(name: "Bottom")
        bottom.side = .bottom
        p.document.layers.append(bottom)
        let shapes = p.document.shapes.filter { $0.layerID == top }.map(\.id)
        try #require(!shapes.isEmpty)
        p.deleteLayer(top)
        for id in shapes {
            let layer = try #require(p.document.shape(id: id).flatMap { p.document.layer(id: $0.layerID) })
            #expect(layer.id != bottom.id && layer.side != .bottom)
        }
    }

    @Test func nestAndMaterialSheetsTogetherWarn() {
        var (p, _) = onSheetB()
        #expect(PreflightChecks.mixedSheets(p.document) == nil)
        p.document.layers.append(Layer(name: "Sheet 2", sheet: SheetSlot(number: 2, offset: Vec2(20, 0))))
        let issue = PreflightChecks.mixedSheets(p.document)
        #expect(issue?.severity == .warning)
        #expect(issue?.message.hasPrefix("Nest sheets and material sheets are both used") == true)
        var single = AppTestSupport.project()
        single.document.layers.append(Layer(name: "Sheet 2", sheet: SheetSlot(number: 2, offset: Vec2(20, 0))))
        #expect(PreflightChecks.mixedSheets(single.document) == nil)
    }
}
