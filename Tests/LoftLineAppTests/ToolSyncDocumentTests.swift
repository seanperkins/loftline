import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The document carries the tools its operations use, follows Tool Database edits into them, and posts with them.
@Suite struct ToolSyncDocumentTests {
    typealias Env = ProjectPostDocumentTests.Env

    /// A project with one profile toolpath, the tool it uses, and a second seeded tool.
    func parts() throws -> (project: LoftLineProject, op: AnyOperation, tool: Tool, other: Tool) {
        var p = AppTestSupport.project()
        let op = try #require(OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id]))
        p.upsertOperation(op)
        let tool = try #require(ToolLibrary.seeded.tool(id: op.setup.toolID))
        return (p, op, tool, ToolLibrary.seeded.tools.first { $0.id != tool.id }!)
    }

    func step(_ um: UndoManager, _ body: () -> Void) { um.beginUndoGrouping(); body(); um.endUndoGrouping() }

    @Test func aToolAddedToAnOperationIsCarriedAtOnce() throws {
        let (p, op, tool, other) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        #expect(doc.project.tools == [tool], "carried when the document opens")
        // A live edit that switches the tool goes through updateOperationLive, not perform.
        var s = op.editableSetup
        s.toolID = other.id
        step(um) { doc.updateOperationLive(op.with(setup: op.editableSetup)) }
        doc.updateOperationLive(op.with(setup: s))
        #expect(doc.project.tools == [other], "the new tool is carried, the unused one dropped")
        // Then the library changes with no reopen: the carried copy follows, and calculating uses it.
        var edited = other
        edited.feedRate = 77
        step(um) { env.library.update(edited) }
        #expect(doc.project.tools == [edited])
        #expect(doc.mergedLibrary.tool(id: other.id)?.feedRate == 77)
    }

    @Test @MainActor func savingWithADifferingLibraryToolLeavesTheFilesToolUnchanged() throws {
        var (p, _, tool, _) = try parts()
        var edited = tool
        edited.feedRate = 55
        p.tools = [edited]
        let env = Env()
        let (doc, _) = env.document(p)
        let saved = try doc.snapshot(contentType: .loftlineProject).project
        #expect(saved.tools == [edited], "the library's feed does not overwrite the file's")
        #expect(env.library.library.tool(id: tool.id) == tool)
    }

    @Test @MainActor func theAppAndTheCommandLinePostTheSameProgramWhenTheLibraryNamesTheToolDifferently() throws {
        var project = try LoftLineProject.decode(from: Data(contentsOf: URL(fileURLWithPath: LoftLineCLITests.sign)))
        let id = ToolLibrary.seeded.tools[0].id
        let at = try #require(project.tools.firstIndex { $0.id == id })
        project.tools[at].name = "Name only in the file"
        let file = LoftLineCLITests.folder().appendingPathComponent("named.loftline")
        try project.encoded().write(to: file)
        let cli = LoftLineCLITests.run(["export", file.path, "--out", "-", "--builtin-only"])
        #expect(cli.status == 0 && cli.out.contains("Name only in the file"), "\(cli.err)")
        let app = try LoftLineCLITests.appExport(project, library: AppTestSupport.library())
        #expect(app == cli.out, "the app's library has the original name; the file's tool still posts")
    }

    @Test func theOperationWarningsAndTheEditorDescribeTheToolThatCuts() throws {
        var (p, op, tool, _) = try parts()
        var carried = tool
        carried.feedRate = 0     // the file's tool has no feed
        p.tools = [carried]
        let (doc, _) = Env().document(p)
        #expect(doc.mergedLibrary.tool(id: tool.id)?.feedRate == 0)
        let warnings = OperationWarnings.make(op, project: doc.project, library: doc.mergedLibrary, profile: doc.postProfile, units: doc.units)
        #expect(warnings.contains { $0.localizedCaseInsensitiveContains("feed") }, "\(warnings)")
    }

    @Test func aLibraryEditFollowsIntoAnOpenProjectMarksItUnsavedAndUndoesAsOneStep() throws {
        let (p, _, tool, _) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        #expect(!doc.needsRecovery)
        var edited = tool
        edited.diameter = 0.375
        step(um) { env.library.update(edited) }
        #expect(doc.project.tools == [edited])
        #expect(doc.needsRecovery, "the project is unsaved")
        #expect(um.undoActionName == "Update Tool from Library")
        um.undo()
        #expect(doc.project.tools == [tool], "one step restores the file's copy")
        #expect(env.library.library.tool(id: tool.id) == edited, "the library is not rolled back")
        #expect(doc.postProfileIssues.contains { $0.message.contains("Update This Project") }, "so the difference is now a warning")
    }

    @Test func anEditOfADifferentToolChangesNothing() throws {
        let (p, _, tool, other) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        var edited = other
        edited.diameter = 0.5
        env.library.update(edited)      // registers nothing: outside an undo group that would raise
        #expect(doc.project.tools == [tool] && !doc.needsRecovery && !um.canUndo)
    }

    @Test func undoingAnEarlierEditDoesNotRollTheLibraryBack() throws {
        let (p, _, tool, _) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        step(um) { doc.perform("Rename job") { $0.document.name = "Renamed" } }
        var edited = tool
        edited.diameter = 0.375
        step(um) { env.library.update(edited) }
        um.undo()
        um.undo()
        #expect(doc.document.name != "Renamed" && doc.project.tools == [tool])
        #expect(env.library.library.tool(id: tool.id) == edited, "undo never touches the library")
    }

    @Test func aToolChangeBumpsTheDesignRevisionIncludingUndoAndRedo() throws {
        let (p, _, tool, _) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        var edited = tool
        edited.diameter = 0.375
        let before = doc.designRevision
        step(um) { env.library.update(edited) }
        let afterEdit = doc.designRevision
        #expect(afterEdit > before)
        um.undo()
        let afterUndo = doc.designRevision
        #expect(afterUndo > afterEdit)
        um.redo()
        #expect(doc.designRevision > afterUndo)
        // Adding a tool with a new operation does not make the other toolpaths stale.
        let (doc2, _) = env.document(AppTestSupport.project())
        let rev = doc2.designRevision
        doc2.perform("New toolpath") { $0.upsertOperation(p.operations[0]) }
        #expect(doc2.designRevision == rev)
    }

    @Test func aClosedProjectWhoseLibraryToolWasEditedWarnsAndPostsTheFilesTool() throws {
        let (p, _, tool, _) = try parts()
        var withFilesTool = p
        withFilesTool.tools = [tool]
        let env = Env()
        var edited = tool
        edited.diameter = 0.5
        env.library.update(edited)          // edited while the project was closed
        let (doc, _) = env.document(withFilesTool)
        #expect(doc.mergedLibrary.tool(id: tool.id)?.diameter == tool.diameter, "the file's tool posts")
        let issue = try #require(doc.postProfileIssues.first { $0.message.contains(tool.name) })
        #expect(issue.severity == .warning && doc.hasCopyDifferences)
        #expect(doc.copyNotice.warnings.contains(issue.message))
    }

    @Test func updateThisProjectReplacesToolsWithThePostAndMachineInOneUndo() throws {
        let (p, _, tool, _) = try parts()
        let env = Env()
        let (doc, um) = env.document(p)
        var post = BuiltInPosts.avidMach4Inch
        post.version = "9.9"
        try env.installPost(post)
        var edited = tool
        edited.diameter = 0.5
        step(um) { env.library.update(edited) }     // follows
        um.undo()                       // back to the file's copy: now it differs again
        #expect(doc.hasCopyDifferences)
        step(um) { doc.updateProjectFromInstalled() }
        #expect(doc.project.tools == [edited])
        #expect(doc.project.postSnapshot.flatMap { try? PostProfile(snapshot: $0) }?.version == "9.9")
        #expect(!doc.hasCopyDifferences)
        um.undo()
        #expect(doc.project.tools == [tool] && doc.hasCopyDifferences, "one undo restores all of it")
    }
}
