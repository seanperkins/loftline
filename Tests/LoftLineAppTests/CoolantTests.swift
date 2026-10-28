import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Coolant is chosen per toolpath and applied when the program is posted: every toolpath of the operation
/// carries it, on every export path, and changing it never recalculates.
@Suite struct CoolantTests {
    /// Two profile toolpaths on the same vectors, both calculated.
    func makeDoc() -> (LoftLineDocument, [UUID]) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.selectAll()
        um.beginUndoGrouping(); doc.addOperation(.profile); doc.addOperation(.profile); um.endUndoGrouping()
        let ids = doc.project.operations.map(\.id)
        doc.calculateNow(ids)
        return (doc, ids)
    }

    func setCoolant(_ doc: LoftLineDocument, _ id: UUID, _ coolant: Coolant?) {
        guard var op = doc.operation(id) else { return }
        var s = op.editableSetup
        s.coolant = coolant
        op.editableSetup = s
        let o = op
        doc.perform("Coolant") { $0.upsertOperation(o) }
    }

    /// The first operation's result, doubled: an operation whose calculation gives two toolpaths.
    func twoToolpathResults(_ doc: LoftLineDocument, _ id: UUID) -> [UUID: ToolpathResult] {
        var results = doc.results
        var r = results[id]!
        r.toolpaths += r.toolpaths
        results[id] = r
        return results
    }

    @Test func theCodesAreFixed() {
        #expect(Coolant.mist.code == "M7")
        #expect(Coolant.air.code == "M8")
    }

    @Test func everyToolpathOfAnOperationGetsItsCoolant() {
        let (doc, ids) = makeDoc()
        setCoolant(doc, ids[0], .air)
        let results = twoToolpathResults(doc, ids[0])
        let all = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: results, groupByTool: false)
        #expect(all.count == 3)
        #expect(all[0].coolant == .air && all[1].coolant == .air)
        #expect(all[2].coolant == nil)
        let one = GCodeExporter.toolpaths(scope: .operation(ids[0]), operations: doc.project.operations, results: results,
                                          groupByTool: false)
        #expect(one.count == 2 && one.allSatisfy { $0.coolant == .air })
    }

    @Test func batchAndValidationAndTiledCarryCoolant() {
        let (doc, ids) = makeDoc()
        setCoolant(doc, ids[0], .mist)
        let profile = BuiltInPosts.avidMach4Inch
        for mode in [SaveAllMode.filePerToolpath, .filePerTool, .oneFileInOrder] {
            let files = GCodeBatchExport.plan(mode: mode, operations: doc.project.operations, results: doc.results,
                                              jobName: "Job", profile: profile)
            let first = files.flatMap(\.toolpaths).first { $0.operationID == ids[0] }
            #expect(first?.coolant == .mist, "\(mode)")
        }
        // What the per-toolpath validation report and the single-toolpath export post.
        #expect(GCodeExporter.operationToolpaths(doc.operation(ids[0])!, results: doc.results).allSatisfy { $0.coolant == .mist })
    }

    @Test func olderFilesDecodeWithCoolantOff() throws {
        let setup = OperationSetup(name: "P", toolID: UUID())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as! [String: Any]
        json.removeValue(forKey: "coolant")
        let back = try JSONDecoder().decode(OperationSetup.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.coolant == nil)
    }

    @Test func changingCoolantLeavesResultsFresh() {
        let (doc, ids) = makeDoc()
        #expect(!doc.isStale(ids[0]))
        setCoolant(doc, ids[0], .mist)
        #expect(!doc.isStale(ids[0]))
        setCoolant(doc, ids[0], .air)
        #expect(!doc.isStale(ids[0]))
    }

    @Test func mergeRefusesDifferentCoolant() {
        let (doc, ids) = makeDoc()
        setCoolant(doc, ids[0], .mist)
        #expect(doc.project.mergeWithNextProblem(ids[0]) == "The next toolpath uses a different coolant.")
        setCoolant(doc, ids[1], .mist)
        #expect(doc.project.mergeWithNextProblem(ids[0]) == nil)
    }

    @Test func splitGivesCoolantBackToEveryChild() throws {
        let (doc, ids) = makeDoc()
        setCoolant(doc, ids[0], .air)
        setCoolant(doc, ids[1], .air)
        var p = doc.project
        let mergedID = p.mergeWithNext(ids[0])
        let merged = try #require(mergedID)
        #expect(p.operations.first { $0.id == merged }?.setup.coolant == .air)
        p.splitMerged(merged)
        #expect(p.operations.allSatisfy { $0.setup.coolant == .air })
    }
}
