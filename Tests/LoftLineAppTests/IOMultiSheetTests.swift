import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOMultiSheetTests {
    @Test func modelSwitchingKeepsEachSheetsJob() throws {
        var d = Document()
        d.job.thickness = 0.75
        #expect(!d.isMultiSheet && d.currentSheetID == MaterialSheet.primaryID)
        var thin = d.job
        thin.thickness = 0.25
        thin.width = 12
        let id = d.addSheet(name: "Thin", job: thin, layerName: "Thin parts", colorHex: "#000000")
        #expect(d.isMultiSheet && d.allSheets.map(\.name) == ["Sheet 1", "Thin"])
        #expect(d.job.thickness == 0.75)
        d.switchToSheet(id)
        #expect(d.job.thickness == 0.25 && d.currentSheetID == id && d.currentSheetName == "Thin")
        #expect(d.job(ofSheet: MaterialSheet.primaryID)?.thickness == 0.75)
        #expect(d.allSheets.map(\.name) == ["Sheet 1", "Thin"])
        d.switchToSheet(MaterialSheet.primaryID)
        #expect(d.job.thickness == 0.75 && d.activeSheetID == nil)
        // Round trip through JSON; older documents have none of the keys.
        let back = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(d))
        #expect(back == d)
        let plain = try JSONEncoder().encode(Document())
        #expect(!String(decoding: plain, as: UTF8.self).contains("otherSheets"))
    }

    func twoSheetDocument() -> (LoftLineDocument, sheet2: UUID, op1: AnyOperation, op2: AnyOperation) {
        let p = AppTestSupport.project()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let firstShape = p.document.shapes[0].id
        doc.addSheet()
        let sheet2 = doc.document.currentSheetID
        // Move the second rectangle to the new sheet's layer and make it thinner.
        let layer2 = doc.currentSheetLayers[0].id
        let shape2 = p.document.shapes[1].id
        doc.perform("x") { $0.moveShapes([shape2], toLayer: layer2); $0.document.job.thickness = 0.5; $0.document.job.zZero = .spoilboard }
        let op1 = OperationFactory.make(kind: .profile, project: doc.project, library: .seeded, shapeIDs: [firstShape])!
        let op2 = OperationFactory.make(kind: .profile, project: doc.project, library: .seeded, shapeIDs: [shape2])!
        doc.perform("ops") { $0.operations = [op1, op2] }
        return (doc, sheet2, op1, op2)
    }

    @Test func sheetsSplitViewOutputAndJobs() throws {
        let (doc, sheet2, op1, op2) = twoSheetDocument()
        #expect(doc.document.currentSheetName == "Sheet 2")
        #expect(doc.currentSheetLayers.count == 1)
        #expect(doc.outputProject.operations.map(\.id) == [op2.id])
        #expect(doc.isOnActiveSide(op2) && !doc.isOnActiveSide(op1))
        doc.selectAll()
        #expect(doc.selection.count == 1)
        // Each operation is calculated with its own sheet's thickness.
        doc.calculateNow([op1.id, op2.id])
        let d1 = doc.results[op1.id]!.toolpaths.compactMap(\.minZ).min()!
        let d2 = doc.results[op2.id]!.toolpaths.compactMap(\.minZ).min()!
        #expect(d1 < -0.4 && d2 > -0.01)
        // Switching back.
        doc.switchSheet(MaterialSheet.primaryID)
        #expect(doc.document.job.thickness == 0.75)
        #expect(doc.outputProject.operations.map(\.id) == [op1.id])
        #expect(doc.document.job(ofSheet: sheet2)?.thickness == 0.5)
        #expect(doc.makeJobSheet(settings: TimeEstimateSettings()).jobName.contains("Sheet 1"))
        // Vectors spanning sheets cannot be calculated.
        var both = op1
        var s = both.editableSetup
        s.shapeIDs = doc.document.shapes.map(\.id)
        both.editableSetup = s
        let r = ToolpathCalculator.calculate(both, project: doc.project, library: .seeded, designRevision: 0, rapidRate: 100)
        #expect(r.error?.contains("more than one") == true)
    }

    @Test func deletingASheetRemovesItsVectors() throws {
        let (doc, sheet2, _, op2) = twoSheetDocument()
        #expect(doc.document.currentSheetID == sheet2)
        let shape2 = op2.setup.shapeIDs[0]
        // Delete without the confirmation alert: drive the model directly.
        doc.perform("Delete Sheet") { p in
            p.document.switchToSheet(MaterialSheet.primaryID)
            let removed = p.document.removeSheet(sheet2)
            p.deleteShapes(removed)
        }
        #expect(!doc.document.isMultiSheet)
        #expect(doc.document.shape(id: shape2) == nil)
        #expect(doc.project.operations.first { $0.id == op2.id }?.setup.shapeIDs.isEmpty == true)
    }

    @Test func unitConversionScalesParkedSheets() throws {
        let (doc, _, _, _) = twoSheetDocument()
        let mm = doc.project.converted(to: .millimeter)
        let parked = try #require(mm.document.otherSheets?.first)
        #expect(abs(parked.job.thickness - 0.75 * 25.4) < 1e-9)
    }
}
