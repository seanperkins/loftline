import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// A rename in the Tool Database is written into calculated toolpaths in place and is not a recalculation, so a
/// note stored at calculation time must not carry the tool's name (issue #60).
@Suite struct StoredWarningNamesTests {
    @Test func aRenameLeavesNoOldNameInTheJobSheetNotes() throws {
        let lib = AppTestSupport.library()
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let op = try #require(OperationFactory.make(kind: .profile, project: p, library: lib.library,
                                                    shapeIDs: [p.document.shapes[0].id]))
        var tool = try #require(lib.library.tool(id: op.setup.toolID))
        tool.fluteLength = 0.1                    // shorter than the cut: the calculation stores a warning
        lib.update(tool)
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: lib)
        doc.calculateNow([op.id])
        func notes() -> (steps: [JobSheet.Step], text: [String]) {
            let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
            return (sheet.steps, sheet.steps.flatMap(\.notes))
        }
        let before = notes()
        #expect(before.text.contains { $0.contains("flute") && $0.contains("the shank rubs the wall") })
        let oldName = tool.name
        #expect(before.text.allSatisfy { !$0.contains(oldName) })
        tool.name = "Renamed in the Tool Database"
        lib.update(tool)
        #expect(!doc.isStale(op.id))              // a label: the toolpaths are not recalculated
        let after = notes()
        #expect(after.text == before.text)
        #expect(after.steps.allSatisfy { !$0.tool.contains(oldName) && $0.tool.contains("Renamed in the Tool Database") })
    }
}
