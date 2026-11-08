import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The export sheets post a program once and keep it; `LoftLineDocument.postedInputs` is how they see that the
/// document has moved on (issue #61), for instance after an edit in the Tool Database window.
@Suite struct PostedInputsTests {
    /// A calculated profile whose tool is in the document's own library.
    func calculatedDoc() throws -> (doc: LoftLineDocument, library: ToolLibraryModel, op: UUID, undo: UndoManager) {
        let lib = AppTestSupport.library()
        var p = AppTestSupport.project()
        let op = try #require(OperationFactory.make(kind: .profile, project: p, library: lib.library,
                                                    shapeIDs: [p.document.shapes[0].id]))
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: lib)
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.calculateNow([op.id])
        return (doc, lib, op.id, um)
    }

    /// The library's copy of the tool the operation cuts with.
    func opTool(_ doc: LoftLineDocument, _ lib: ToolLibraryModel, _ op: UUID) throws -> Tool {
        let operation = try #require(doc.operation(op))
        return try #require(lib.library.tool(id: operation.setup.toolID))
    }

    @Test func itIsStableUntilSomethingChanges() throws {
        let (doc, _, op, _) = try calculatedDoc()
        let before = doc.postedInputs
        #expect(doc.postedInputs == before)
        // Selection, the toolpath list's highlight and a repeated read are not inputs of a program.
        doc.setSelection([doc.document.shapes[0].id])
        doc.selectedOperationID = op
        #expect(doc.postedInputs == before)
    }

    @Test func thePostProcessorAndTheGroupByToolPreferenceAreStampedOn() throws {
        let (doc, _, _, _) = try calculatedDoc()
        let post = BuiltInPosts.avidMach4Inch
        var reloaded = post
        reloaded.name += " (edited)"           // what Reload Post Profiles brings in
        let stamped = doc.postedInputs.stamped(profile: post)
        #expect(stamped == doc.postedInputs.stamped(profile: post))
        #expect(stamped != doc.postedInputs)
        #expect(stamped != doc.postedInputs.stamped(profile: reloaded))
        #expect(stamped != doc.postedInputs.stamped(profile: post, groupedByTool: true))
        #expect(stamped.stamped(profile: post, groupedByTool: true) == doc.postedInputs.stamped(profile: post, groupedByTool: true))
    }

    @Test func aToolEditThatChangesToolpathsChangesIt() throws {
        let (doc, lib, op, _) = try calculatedDoc()
        let before = doc.postedInputs
        var tool = try opTool(doc, lib, op)
        tool.diameter += 0.0625
        lib.update(tool)
        #expect(doc.postedInputs != before)
        #expect(doc.isStale(op))
    }

    @Test func aToolRenameChangesItWithoutMakingToolpathsStale() throws {
        let (doc, lib, op, _) = try calculatedDoc()
        let before = doc.postedInputs
        var tool = try opTool(doc, lib, op)
        tool.name = "Renamed in the Tool Database"
        lib.update(tool)
        #expect(!doc.isStale(op))   // a label: nothing is recalculated, the result takes the name in place
        #expect(doc.results[op]?.toolpaths.first?.tool.name == "Renamed in the Tool Database")
        #expect(doc.postedInputs != before)
    }

    @Test func anEditAndItsUndoBothChangeIt() throws {
        let (doc, _, _, um) = try calculatedDoc()
        let start = doc.postedInputs
        um.beginUndoGrouping(); doc.perform("Job") { $0.document.job.thickness += 0.25 }; um.endUndoGrouping()
        let edited = doc.postedInputs
        #expect(edited != start)
        um.undo()
        #expect(doc.postedInputs != edited)
    }

    @Test func aStoredResultAndASideSwitchChangeIt() throws {
        let (doc, _, op, _) = try calculatedDoc()
        let before = doc.postedInputs
        doc.calculateNow([op])
        let recalculated = doc.postedInputs
        #expect(recalculated != before)
        doc.perform("Two-sided") { $0.document.job.twoSided = TwoSidedSetup() }
        let twoSided = doc.postedInputs
        doc.activeSide = .bottom   // the program is posted from the side showing
        #expect(doc.postedInputs != twoSided)
    }

    @Test func aLiveToolpathEditChangesIt() throws {
        let (doc, _, op, um) = try calculatedDoc()
        func renamed(_ name: String) throws -> AnyOperation {
            var o = try #require(doc.operation(op))
            var s = o.editableSetup
            s.name = name
            o.editableSetup = s
            return o
        }
        um.beginUndoGrouping(); doc.updateOperationLive(try renamed("First edit")); um.endUndoGrouping()
        let first = doc.postedInputs
        doc.updateOperationLive(try renamed("Second edit"))   // merges into the open undo step, no new one
        #expect(doc.operation(op)?.setup.name == "Second edit")
        #expect(doc.postedInputs != first)
    }
}
