import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// LoftLineDocument wiring for the inlay wizard, STL placement dialog and tab editor.
@Suite struct AdvancedToolpathDocumentTests {
    func makeDoc() -> (LoftLineDocument, UndoManager) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        return (doc, um)
    }

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    static let stl = """
    solid t
    facet normal 0 0 1
    outer loop
    vertex 0 0 0
    vertex 2 0 0
    vertex 1 1 0.5
    endloop
    endfacet
    facet normal 0 0 1
    outer loop
    vertex 0 0 0
    vertex 1 1 0.5
    vertex 0 2 0
    endloop
    endfacet
    endsolid t
    """

    @Test func newInlayOpensTheWizard() {
        let (doc, _) = makeDoc()
        doc.addOperation(.inlay)
        #expect(doc.sheet == .inlayWizard)
        #expect(doc.project.operations.isEmpty)
    }

    @Test func wizardAddsBothInlayToolpathsInOneUndoStep() {
        let (doc, um) = makeDoc()
        let w = InlayWizardModel(project: doc.project, library: doc.mergedLibrary, shapeIDs: [doc.document.shapes[0].id])
        step(um) { doc.addInlay(w) }
        #expect(doc.project.operations.count == 2)
        #expect(doc.selectedOperationID == doc.project.operations[0].id)
        um.undo()
        #expect(doc.project.operations.isEmpty)
    }

    @Test func importingAnSTLShowsThePlacementDialog() throws {
        let (doc, um) = makeDoc()
        let url = AppTestSupport.tempDir().appendingPathComponent("bump.stl")
        try Data(Self.stl.utf8).write(to: url)
        doc.importFiles([url])
        guard case .placeModel(let form) = doc.sheet else { Issue.record("expected placement sheet"); return }
        #expect(form.name == "bump")
        #expect(doc.document.models.isEmpty) // nothing changes until the dialog is accepted
        step(um) { doc.applyPlacement(form) }
        #expect(doc.document.models.count == 1)
        #expect(doc.project.operations.map(\.setup.name) == ["bump Roughing", "bump Finishing"])
        um.undo()
        #expect(doc.document.models.isEmpty && doc.project.operations.isEmpty)
    }

    @Test func editingAPlacementUpdatesTheModelInPlace() {
        let (doc, um) = makeDoc()
        var f = ModelPlacementForm(mesh: ModelPlacementFormTests.mesh, name: "Pyr", job: doc.document.job,
                                   library: doc.mergedLibrary)
        f.createToolpaths = false
        step(um) { doc.applyPlacement(f) }
        doc.editPlacement(of: f.modelID)
        guard case .placeModel(var e) = doc.sheet else { Issue.record("expected placement sheet"); return }
        e.zHeight = 0.25
        step(um) { doc.applyPlacement(e) }
        #expect(doc.document.models.count == 1)
        #expect(abs(doc.document.models[0].depth - 0.25) < 1e-12)
        #expect(doc.project.operations.isEmpty)
    }

    @Test func tabEditsAreUndoableAndEditingEndsWhenTheToolpathGoes() throws {
        let (doc, um) = makeDoc()
        doc.setSelection([doc.document.shapes[0].id])
        step(um) { doc.addOperation(.profile) }
        let id = try #require(doc.selectedOperationID)
        doc.tabEditingOperationID = id
        let tabs = try #require(TabEditor.adding(at: Vec2(2, 1), to: TabSettings(), shapes: doc.selectedShapes,
                                                 maxDistance: 0.1, tolerance: 0.001))
        step(um) { doc.setProfileTabs(tabs, for: id, actionName: "Add Tab") }
        #expect(doc.operation(id)?.profileTabs?.manualTabs?.count == 1)
        #expect(um.undoActionName == "Add Tab")
        um.undo()
        #expect(doc.operation(id)?.profileTabs?.manualTabs == nil)
        step(um) { doc.deleteOperation(id) }
        #expect(doc.tabEditingOperationID == nil)
    }
}

/// Toolpath editor write-through: edits are live, merged into one undo step per session.
@Suite struct LiveOperationEditTests {
    func makeDoc() -> (LoftLineDocument, UndoManager, AnyOperation) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        let op = OperationFactory.make(kind: .profile, project: doc.project, library: .seeded,
                                       shapeIDs: [doc.document.shapes[0].id])!
        step(um) { doc.updateOperation(op) }
        um.removeAllActions()
        return (doc, um, op)
    }

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    func renamed(_ op: AnyOperation, _ name: String) -> AnyOperation {
        var o = op
        var s = o.editableSetup
        s.name = name
        o.editableSetup = s
        return o
    }

    @Test func editsAreCommittedImmediatelyAndMergeIntoOneUndoStep() {
        let (doc, um, op) = makeDoc()
        step(um) { doc.updateOperationLive(renamed(op, "A")) }
        // Merged edits register nothing (an undo grouping would be needed otherwise).
        for name in ["AB", "ABC"] { doc.updateOperationLive(renamed(op, name)) }
        #expect(doc.operation(op.id)?.setup.name == "ABC")
        um.undo()
        #expect(doc.operation(op.id)?.setup.name == op.setup.name)
        #expect(!um.canUndo)
        um.redo()
        #expect(doc.operation(op.id)?.setup.name == "ABC")
    }

    @Test func anInterveningChangeStartsANewUndoStep() {
        let (doc, um, op) = makeDoc()
        step(um) { doc.updateOperationLive(renamed(op, "A")) }
        step(um) { doc.perform("Other") { $0.document.job.safeZ += 0.1 } }
        step(um) { doc.updateOperationLive(renamed(op, "B")) }
        um.undo()
        #expect(doc.operation(op.id)?.setup.name == "A")
    }

    @Test func liveEditNeverResurrectsADeletedOperation() {
        let (doc, um, op) = makeDoc()
        step(um) { doc.deleteOperation(op.id) }
        doc.updateOperationLive(renamed(op, "Ghost"))
        #expect(doc.operation(op.id) == nil)
    }
}
