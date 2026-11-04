import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct LayoutProductionPlateCommandTests {
    /// A 6 x 2 in plate at (1, 15) on 24 x 18 material with centred "{Name}" text and a
    /// profile + V-carve toolpath.
    func project() throws -> (LoftLineProject, plate: UUID, text: UUID) {
        var doc = Document(job: JobSetup(width: 24, height: 18))
        let l = doc.defaultLayerID
        let plate = AppTestSupport.rect(1, 15, 6, 2, layer: l)
        let spec = TextSpec(string: "{Name}", fontName: "Helvetica", size: 0.5, alignment: .center, anchor: Vec2(4, 15.75))
        let text = try TextOutliner().shape(for: spec, layerID: l)
        doc.add(plate); doc.add(text)
        var p = LoftLineProject(document: doc)
        for (kind, ids) in [(OperationKind.profile, [plate.id]), (.vcarve, [text.id])] {
            if let op = OperationFactory.make(kind: kind, project: p, library: .seeded, shapeIDs: ids) { p.upsertOperation(op) }
        }
        return (p, plate.id, text.id)
    }

    @Test func makesOnePlatePerRecordWithToolpaths() throws {
        var (p, plate, text) = try project()
        let table = CSVTable.parse("Name\nAda\nAlan\nGrace\n")
        var o = ProductionPlateOptions.defaults(for: .inch)
        o.columns = 2
        let r = try ProductionPlateCommands.make([plate, text], table: table, options: o, in: &p)
        #expect(r.plates == 3)
        #expect(r.shapeIDs.count == 6)
        #expect(r.missingFields.isEmpty && r.outsideMaterial == 0)
        #expect(p.document.shapes.count == 6)
        let texts = p.document.shapes.compactMap(\.text).map(\.string)
        #expect(texts == ["Ada", "Alan", "Grace"])
        // Second plate is one plate width + gap to the right, third is a row below.
        let outlines = p.document.shapes.filter { $0.text == nil }.map { $0.bounds().min }
        #expect(outlines.contains(Vec2(7.5, 15)))
        #expect(outlines.contains(Vec2(1, 12.5)))
        // Each text stays centred on its plate.
        let grace = p.document.shapes.first { $0.text?.string == "Grace" }!.bounds()
        #expect(abs(grace.center.x - 4) < 0.05)
        // Both toolpaths now machine every plate.
        #expect(r.operationsUpdated == 2)
        #expect(p.operations.allSatisfy { $0.setup.shapeIDs.count == 3 })
    }

    @Test func shrinksLongTextFitsColumnsAndReportsProblems() throws {
        var (p, plate, text) = try project()
        let i = p.document.shapes.firstIndex { $0.id == text }!
        p.document.shapes[i].text?.string = "{Name} {Title}"
        let names = [String(repeating: "W", count: 40)] + (2...24).map { "N\($0)" }
        let table = CSVTable.parse("Name\n" + names.joined(separator: "\n"))
        var o = ProductionPlateOptions.defaults(for: .inch)
        o.includeToolpaths = false
        let r = try ProductionPlateCommands.make([plate, text], table: table, options: o, in: &p)
        #expect(r.plates == 24)
        #expect(r.missingFields == ["Title"])
        #expect(r.shrunk == 1)
        #expect(r.operationsUpdated == 0)
        #expect(p.operations.allSatisfy { $0.setup.shapeIDs.count == 1 })
        // 3 plates fit across 24 in; 8 rows going down from y = 15 → the last row is off the material.
        #expect(r.outsideMaterial == 3)
        let first = p.document.shape(id: text)!
        #expect(first.text?.string.hasSuffix(" {Title}") == true)
        #expect(first.bounds().width <= 5.5 + 1e-6)
        #expect(abs(first.bounds().center.x - 4) < 0.05)
    }

    @Test func refusesWithoutPlaceholdersOrRecords() throws {
        var (p, plate, text) = try project()
        let o = ProductionPlateOptions.defaults(for: .inch)
        #expect(throws: ProductionPlateCommands.Failure.noPlaceholders) {
            try ProductionPlateCommands.make([plate], table: CSVTable.parse("Name\nA"), options: o, in: &p)
        }
        #expect(throws: ProductionPlateCommands.Failure.noRecords) {
            try ProductionPlateCommands.make([plate, text], table: CSVTable.parse("Name\n"), options: o, in: &p)
        }
        #expect(ProductionPlateCommands.fields([plate, text], in: p) == ["Name"])
    }

    @Test func mergedToolpathPartsGetThePlatesToo() throws {
        var (p, plate, text) = try project()
        let parts = p.operations
        var merge = MergeOperation(setup: OperationSetup(name: "Merged", toolID: parts[0].setup.toolID,
                                                         shapeIDs: [plate, text]),
                                   params: MergeParameters(children: parts))
        merge.setup.isEnabled = true
        p.operations = [.merge(merge)]
        let o = ProductionPlateOptions.defaults(for: .inch)
        _ = try ProductionPlateCommands.make([plate, text], table: CSVTable.parse("Name\nA\nB"), options: o, in: &p)
        guard case .merge(let m) = p.operations[0] else { Issue.record("not a merge"); return }
        #expect(m.setup.shapeIDs.count == 4)
        #expect(m.params.children.allSatisfy { $0.setup.shapeIDs.count == 2 })
    }
}
