import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// A Tool Database edit is one write of tools.json, and only an edit that can change a toolpath
/// makes open documents' toolpaths stale.
@MainActor
@Suite struct ToolLibraryCommitTests {
    func edit(_ lib: ToolLibraryModel, _ change: (inout Tool) -> Void) throws -> Tool {
        var t = try #require(lib.tools.first)
        change(&t)
        return t
    }

    @Test func aNameEditIsOneWriteAndNoStaleMark() throws {
        let lib = AppTestSupport.library()
        let before = (lib.writes, lib.revision)
        #expect(lib.commitEdit(try edit(lib) { $0.name = "Renamed bit" }))
        #expect(lib.writes == before.0 + 1)
        #expect(lib.revision == before.1)
        #expect(ToolLibraryModel(store: lib.store).tools.first?.name == "Renamed bit")
    }

    @Test func notesAndFolderAreLabelsToo() throws {
        let lib = AppTestSupport.library()
        let r = lib.revision
        #expect(lib.commitEdit(try edit(lib) { $0.notes = "Bought at the show" }))
        #expect(lib.commitEdit(try edit(lib) { $0.group = "Favourites" }))
        #expect(lib.revision == r)
        #expect(lib.writes == 2)
    }

    @Test func aDiameterEditIsOneWriteAndOneStaleMark() throws {
        let lib = AppTestSupport.library()
        let before = (lib.writes, lib.revision)
        #expect(lib.commitEdit(try edit(lib) { $0.diameter += 0.01 }))
        #expect(lib.writes == before.0 + 1)
        #expect(lib.revision == before.1 + 1)
    }

    @Test func everyFieldThatReachesTheProgramMarksToolpathsStale() throws {
        let changes: [(String, (inout Tool) -> Void)] = [
            ("feed", { $0.feedRate += 1 }), ("plunge", { $0.plungeRate += 1 }), ("rpm", { $0.spindleRPM += 100 }),
            ("stepdown", { $0.stepdown /= 2 }), ("stepover", { $0.stepover /= 2 }), ("flutes", { $0.flutes += 1 }),
            ("number", { $0.number += 40 }), ("kind", { $0.kind = .ballNose }), ("units", { $0 = $0.converted(to: .millimeter) }),
            ("flute length", { $0.fluteLength = 0.2 }),
            ("angle", { $0.angle = 45 }), ("tip diameter", { $0.tipDiameter = 0.02 }),
            ("shape", { $0.shape = ToolShapeChoice.bullNose.defaultShape(for: $0) }),
            ("material data", { $0.materials = [MaterialCuttingData(material: "Oak", from: $0)] }),
        ]
        for (name, change) in changes {
            let lib = AppTestSupport.library()
            let r = lib.revision
            #expect(lib.commitEdit(try edit(lib, change)), Comment(rawValue: name))
            #expect(lib.revision == r + 1, Comment(rawValue: name))
        }
    }

    @Test func addingOrRemovingAToolMarksToolpathsStale() throws {
        let lib = AppTestSupport.library()
        var r = lib.revision
        let added = lib.add(kind: .endMill)
        #expect(lib.revision == r + 1); r = lib.revision
        lib.delete(id: added.id)
        #expect(lib.revision == r + 1)
    }

    @Test func aChangeThatChangesNothingWritesNothing() throws {
        let lib = AppTestSupport.library()
        let first = try #require(lib.tools.first)
        lib.update(first)
        lib.restoreDefaults()
        lib.delete(id: UUID())
        lib.importTools([first])
        #expect(lib.writes == 0)
        #expect(lib.revision == 0)
    }

    /// The document side: a renamed tool leaves calculated toolpaths valid, a re-sized one does not.
    @Test func documentsGoStaleOnlyForAnEditThatCanChangeTheirToolpaths() throws {
        let lib = AppTestSupport.library()
        var p = AppTestSupport.project()
        let tool = try #require(lib.tools.first { $0.kind == .endMill })
        var op = try #require(OperationFactory.make(kind: .profile, project: p, library: lib.library,
                                                    shapeIDs: [p.document.shapes[0].id]))
        var s = op.editableSetup
        s.toolID = tool.id
        op.editableSetup = s
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: lib)
        doc.calculateNow([op.id])
        #expect(!doc.isStale(op.id))

        var renamed = tool
        renamed.name = "Renamed bit"
        renamed.notes = "Dull"
        #expect(lib.commitEdit(renamed))
        #expect(!doc.isStale(op.id))

        var wider = renamed
        wider.diameter += 0.05
        #expect(lib.commitEdit(wider))
        #expect(doc.isStale(op.id))
    }

    @Test func renamingAMaterialEntryIsNotALabel() throws {
        let lib = AppTestSupport.library()
        var t = try #require(lib.tools.first)
        t.materials = [MaterialCuttingData(material: "Oak", from: t)]
        #expect(lib.commitEdit(t))
        let r = lib.revision
        t.materials?[0].material = "Maple"
        #expect(lib.commitEdit(t))
        #expect(lib.revision == r + 1)
    }

    @Test func restoringADeletedDefaultMarksToolpathsStale() throws {
        let lib = AppTestSupport.library()
        let gone = try #require(lib.tools.first)
        lib.delete(id: gone.id)
        let r = lib.revision
        lib.restoreDefaults()
        #expect(lib.library.tool(id: gone.id) != nil)
        #expect(lib.revision == r + 1)
    }

    @Test func aFailedSaveIsRetriedByTheNextChangeEvenWhenItChangesNothing() throws {
        let dir = AppTestSupport.tempDir()
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let lib = ToolLibraryModel(store: ToolLibraryStore(fileURL: blocker.appendingPathComponent("tools.json")))
        #expect(lib.commitEdit(try edit(lib) { $0.diameter += 0.01 }))
        #expect(lib.writes == 0)
        #expect(lib.lastError != nil)
        try FileManager.default.removeItem(at: blocker)
        lib.restoreDefaults()   // changes nothing, but the file is behind
        #expect(lib.writes == 1)
        #expect(lib.lastError == nil)
        #expect(ToolLibraryModel(store: lib.store).tools.first?.diameter == lib.tools.first?.diameter)
    }

    @Test func aTextEditStillBeingTypedIsSeenByDuplicateAndExport() throws {
        let lib = AppTestSupport.library()
        var typed = try #require(lib.tools.first)
        typed.name = "Half typed na"
        lib.hold(typed)
        #expect(lib.library.tool(id: typed.id)?.name != "Half typed na")
        let copy = try #require(lib.duplicate(id: typed.id))
        #expect(copy.name == "Half typed na copy")
        #expect(lib.library.tool(id: typed.id)?.name == "Half typed na")
        // Deleting the tool drops its draft: nothing is brought back later.
        typed.name = "Typed again"
        lib.hold(typed)
        lib.delete(id: typed.id)
        lib.restoreDefaults()
        #expect(lib.library.tool(id: typed.id)?.name != "Typed again")
    }

    @Test func aTypeChangeAndItsDefaultAngleAreOneEdit() throws {
        let lib = AppTestSupport.library()
        var t = try #require(lib.tools.first { $0.kind == .endMill })
        #expect(t.angle == nil)
        t.setKind(.vBit)
        #expect(t.angle == 60)
        let w = lib.writes
        #expect(lib.commitEdit(t))
        #expect(lib.writes == w + 1)
        t.angle = 90
        t.setKind(.engraving)
        #expect(t.angle == 90)
    }

    /// Calculated toolpaths show a renamed tool without being recalculated.
    @Test func aRenameReachesCalculatedToolpathsAndTheSummaryWithoutRecalculating() throws {
        let lib = AppTestSupport.library()
        var p = AppTestSupport.project()
        let tool = try #require(lib.tools.first { $0.kind == .endMill })
        var op = try #require(OperationFactory.make(kind: .profile, project: p, library: lib.library,
                                                    shapeIDs: [p.document.shapes[0].id]))
        var setup = op.editableSetup
        setup.toolID = tool.id
        op.editableSetup = setup
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: lib)
        doc.calculateNow([op.id])
        let before = doc.jobSummary(groupByTool: false, settings: TimeEstimateSettings())
        #expect(before.rows.first?.tools.first?.contains(tool.name) == true)
        var renamed = tool
        renamed.name = "Renamed bit"
        #expect(lib.commitEdit(renamed))
        #expect(!doc.isStale(op.id))
        let names = Set((doc.results[op.id]?.toolpaths ?? []).map(\.tool.name))
        #expect(names == ["Renamed bit"])
        let after = doc.jobSummary(groupByTool: false, settings: TimeEstimateSettings())
        #expect(after.rows.first?.tools == ["T\(tool.number) · Renamed bit"])
    }

    /// Which tool changes wait for the focused field, and which save at once.
    @Test func onlyTheFocusedFieldsOwnTextWaitsForTheFieldToBeLeft() throws {
        var t = try #require(AppTestSupport.library().tools.first)
        t.materials = [MaterialCuttingData(material: "Oak", from: t), MaterialCuttingData(material: "Pine", from: t)]
        func changed(_ change: (inout Tool) -> Void) -> Tool { var n = t; change(&n); return n }

        #expect(ToolEditorField.name.isTextEdit(from: t, to: changed { $0.name += "x" }))
        #expect(ToolEditorField.notes.isTextEdit(from: t, to: changed { $0.notes += "x" }))
        #expect(ToolEditorField.group.isTextEdit(from: t, to: changed { $0.group = "Fav" }))
        #expect(ToolEditorField.material(1).isTextEdit(from: t, to: changed { $0.materials?[1].material = "Pin" }))
        // A different control changed, or a different field: saved at once.
        #expect(!ToolEditorField.name.isTextEdit(from: t, to: changed { $0.name += "x"; $0.feedRate += 1 }))
        #expect(!ToolEditorField.name.isTextEdit(from: t, to: changed { $0 = $0.converted(to: .millimeter) }))
        #expect(!ToolEditorField.name.isTextEdit(from: t, to: changed { $0.setKind(.vBit) }))
        #expect(!ToolEditorField.name.isTextEdit(from: t, to: changed { $0.notes = "other" }))
        #expect(!ToolEditorField.material(0).isTextEdit(from: t, to: changed { $0.materials?[1].material = "Pin" }))
        #expect(!ToolEditorField.material(1).isTextEdit(from: t, to: changed { $0.materials?.removeLast() }))
        #expect(!ToolEditorField.material(1).isTextEdit(from: t, to: changed { $0.materials?[1].feedRate += 1 }))
    }

    /// The editor's own save paths (Return, leaving a field, closing, quitting) are commitEdit with an
    /// unchanged tool; they must still retry a save that failed.
    @Test func aFailedSaveIsRetriedWhenTheEditorSavesAgain() throws {
        let dir = AppTestSupport.tempDir()
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let lib = ToolLibraryModel(store: ToolLibraryStore(fileURL: blocker.appendingPathComponent("tools.json")))
        let edited = try edit(lib) { $0.diameter += 0.01 }
        #expect(lib.commitEdit(edited))
        #expect(lib.lastError != nil)
        try FileManager.default.removeItem(at: blocker)
        #expect(!lib.commitEdit(edited))   // the library already has it, but the file does not
        #expect(lib.lastError == nil)
        #expect(lib.writes == 1)
        #expect(ToolLibraryModel(store: lib.store).tools.first?.diameter == edited.diameter)
    }

    /// Renaming a tool is not a new simulation: a preview part-way through a cut keeps its place.
    @Test func aRenamedToolDoesNotRestartThe3DSimulation() throws {
        let job = JobSetup(width: 10, height: 10, thickness: 0.75)
        let coords = MachineCoordinates(job: job)
        let tool = Tool(name: "EM", kind: .endMill, number: 1, diameter: 0.25, stepdown: 0.1, stepover: 0.1,
                        feedRate: 60, plungeRate: 20)
        func slot(_ tool: Tool) -> Toolpath {
            Toolpath(name: "slot", kind: .profile, tool: tool, moves: [
                .rapid(to: coords.machineAtSafeZ(Vec2(1, 1))),
                .linear(to: coords.machine(Vec2(1, 1), depth: 0.2), feed: 18),
                .linear(to: coords.machine(Vec2(7, 1), depth: 0.2), feed: 60),
                .rapid(to: coords.machineAtSafeZ(Vec2(7, 1))),
            ])
        }
        let model = SimulationPreviewModel()
        var path = slot(tool)
        model.configure(job: job, toolpaths: [path], rapidRate: 180, units: .inch)
        let part = model.totalTime / 2
        model.time = part
        path.tool.name = "Renamed"   // what the document does to a calculated toolpath
        model.configure(job: job, toolpaths: [path], rapidRate: 180, units: .inch)
        #expect(model.time == part)
        path.tool.diameter = 0.5
        model.configure(job: job, toolpaths: [path], rapidRate: 180, units: .inch)
        #expect(model.time == model.totalTime)
    }

    /// An import with Replace that puts the editor's own starting version back still has to reach the
    /// editor: the typed text was saved first, then replaced, so the library differs from the draft.
    @Test func anImportThatReplacesTheToolIsShownEvenWhenItRestoresTheStartingVersion() throws {
        let lib = AppTestSupport.library()
        let start = try #require(lib.tools.first)
        let file = AppTestSupport.tempDir().appendingPathComponent("one.loftlinetools")
        try lib.export(ids: [start.id], to: file)
        var typed = start
        typed.name = "Half typed"
        lib.hold(typed)
        #expect(lib.replacement(for: typed) == nil)   // its own held edit is not a replacement
        let (tools, conflicts) = try lib.readImport(file)
        #expect(conflicts.count == 1)                 // judged against the tool as typed
        _ = lib.importTools(tools, policy: .replace)
        #expect(lib.library.tool(id: start.id) == start)
        #expect(lib.replacement(for: typed) == start)
        #expect(lib.replacement(for: start) == nil)
    }

    /// Browsing the Tool Database must not rewrite a tools.json that could not be read.
    @Test func anUnreadableToolFileIsLeftAloneUntilARealChange() throws {
        let dir = AppTestSupport.tempDir()
        let file = dir.appendingPathComponent("tools.json")
        try Data("not json".utf8).write(to: file)
        let lib = ToolLibraryModel(store: ToolLibraryStore(fileURL: file))
        #expect(lib.lastError != nil)
        let first = try #require(lib.tools.first)
        #expect(!lib.commitEdit(first))   // leaving a tool in the editor, nothing edited
        lib.restoreDefaults()
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
        #expect(lib.lastError != nil)
        #expect(lib.writes == 0)
        var edited = first
        edited.feedRate += 1
        #expect(lib.commitEdit(edited))
        #expect(lib.writes == 1)
        #expect(lib.lastError == nil)
        #expect(ToolLibraryModel(store: lib.store).tools.first?.feedRate == edited.feedRate)
    }

    /// Export Selected Tool builds the save panel's suggested file name before the file is written: with the Name
    /// field still being typed in, the name must be the typed one (the exported file contains it), not the old one.
    @Test func theSuggestedExportNameIsTheNameBeingTyped() throws {
        let lib = AppTestSupport.library()
        var typed = try #require(lib.tools.first)
        let id = typed.id
        let old = typed.name
        typed.name = "Typed name"
        lib.hold(typed)
        #expect(lib.library.tool(id: id)?.name == old)           // not saved yet: the field has focus
        #expect(lib.exportName(for: [id]) == "Typed name")
        #expect(lib.library.tool(id: id)?.name == "Typed name")  // and now it is, the same way export itself saves it
        #expect(lib.exportName(for: nil) == "LoftLine Tools")
        #expect(lib.exportName(for: [UUID()]) == "LoftLine Tools")
    }
}

