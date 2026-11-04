import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct LayoutPartLabelCommandTests {
    /// Two plates (the first with a hole on its left) and a tiny tab.
    func project() -> (LoftLineProject, [UUID]) {
        var doc = Document(job: JobSetup(width: 30, height: 20))
        let l = doc.defaultLayerID
        var plate = AppTestSupport.rect(1, 1, 10, 4, layer: l)
        plate.name = ""
        let hole = Shape(name: "", layerID: l, paths: [ShapeFactory.circle(center: Vec2(3.5, 3), radius: 1.5)])
        var shelf = AppTestSupport.rect(1, 8, 12, 5, layer: l)
        shelf.name = "Shelf"
        let tiny = AppTestSupport.rect(20, 1, 0.1, 0.1, layer: l)
        [plate, hole, shelf, tiny].forEach { doc.add($0) }
        return (LoftLineProject(document: doc), [plate.id, hole.id, shelf.id, tiny.id])
    }

    @Test func labelsEachPartOnItsOwnLayer() throws {
        var (p, ids) = project()
        var o = PartLabelOptions.defaults(for: .inch)
        o.text = .both
        let r = try PartLabelCommands.label(ids, options: o, library: .seeded, in: &p)
        #expect(r.labelIDs.count == 2)
        #expect(r.skipped == 1)
        let labels = r.labelIDs.compactMap { p.document.shape(id: $0) }
        #expect(labels.allSatisfy { p.document.layer(id: $0.layerID)?.name == PartLabelCommands.layerName })
        #expect(p.document.shape(id: ids[0])?.name == "Part 1")
        #expect(labels.contains { $0.name == "Label 2 Shelf" })
        // The plate's label stays on the plate and clear of the hole.
        let plateLabel = labels.first { $0.name.hasPrefix("Label 1") }!.bounds()
        #expect(plateLabel.min.x > 5 && plateLabel.max.x < 11 && plateLabel.min.y > 1 && plateLabel.max.y < 5)
        #expect(plateLabel.height <= o.maxHeight * 1.1)  // cap height; digits overshoot a little
    }

    @Test func relabellingReplacesOldLabelsAndCanAddAToolpath() throws {
        var (p, ids) = project()
        var o = PartLabelOptions.defaults(for: .inch)
        _ = try PartLabelCommands.label(ids, options: o, library: .seeded, in: &p)
        o.addToolpath = true
        let r = try PartLabelCommands.label(ids, options: o, library: .seeded, in: &p)
        let layer = p.document.layers.first { $0.name == PartLabelCommands.layerName }!
        #expect(p.document.shapes(inLayer: layer.id).count == 2)
        #expect(p.document.layers.filter { $0.name == PartLabelCommands.layerName }.count == 1)
        #expect(r.operationID != nil)
        #expect(p.operations.first?.kind == .vcarve)
        #expect(Set(p.operations.first?.setup.shapeIDs ?? []) == Set(r.labelIDs))
    }

    @Test func jobSheetListsAndPrintsPartNames() throws {
        var (p, ids) = project()
        _ = try PartLabelCommands.label(ids, options: .defaults(for: .inch), library: .seeded, in: &p)
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let js = doc.makeJobSheet(settings: TimeEstimateSettings())
        #expect(js.sheets[0].partNames.contains("Part 1"))
        #expect(js.sheets[0].partNames.contains("Shelf"))
        #expect(js.sheets[0].partNames.count == 3)  // labels are not parts
        #expect(JobSheetHTML.render(js).contains(">Shelf</text>"))
    }
}
