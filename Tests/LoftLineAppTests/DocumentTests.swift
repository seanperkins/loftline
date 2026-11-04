import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct LoftLineDocumentTests {
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

    @Test func performIsUndoableAndRedoable() {
        let (doc, um) = makeDoc()
        let original = doc.project
        doc.setSelection([doc.document.shapes[0].id])
        step(um) { doc.translateSelection(by: Vec2(1, 0)) }
        #expect(doc.project != original)
        #expect(um.undoActionName == "Move")
        um.undo()
        #expect(doc.project == original)
        um.redo()
        #expect(abs(doc.document.shapes[0].bounds().min.x - 2) < 1e-9)
    }

    @Test func noOpChangesRegisterNothing() {
        let (doc, um) = makeDoc()
        doc.perform("Nothing") { _ in }
        #expect(!um.canUndo)
    }

    @Test func deletingPrunesSelection() {
        let (doc, um) = makeDoc()
        doc.selectAll()
        #expect(doc.selection.count == 2)
        step(um) { doc.deleteSelection() }
        #expect(doc.selection.isEmpty)
        #expect(doc.document.shapes.isEmpty)
    }

    @Test func selectionKeepsClickOrder() {
        let (doc, _) = makeDoc()
        let a = doc.document.shapes[0].id, b = doc.document.shapes[1].id
        doc.select(b, extending: false)
        doc.select(a, extending: true)
        #expect(doc.selectedShapes.map(\.id) == [b, a])
        doc.select(b, extending: true)
        #expect(doc.selectedShapes.map(\.id) == [a])
    }

    @Test func addOperationUsesSelectionAndSelectsIt() {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        #expect(doc.project.operations.count == 1)
        #expect(doc.selectedOperationID == doc.project.operations[0].id)
        #expect(doc.project.operations[0].setup.shapeIDs.count == 2)
        #expect(doc.sidebarTab == .toolpaths)
    }

    @Test func resultsGoStaleWhenDesignOrParametersChange() {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        let id = doc.project.operations[0].id
        doc.calculateNow([id])
        #expect(doc.results[id] != nil)
        #expect(!doc.isStale(id))
        step(um) { doc.translateSelection(by: Vec2(0, 1)) }
        #expect(doc.isStale(id))
        doc.calculateNow([id])
        #expect(!doc.isStale(id))
        step(um) { doc.setOperationEnabled(id, false) }
        #expect(doc.isStale(id))
    }

    @MainActor
    private func waitForCalculations(_ doc: LoftLineDocument) async throws {
        for _ in 0..<2000 where !doc.calculating.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(doc.calculating.isEmpty)
    }

    @MainActor @Test func backgroundCalculationCanBeAwaited() async {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        let id = doc.project.operations[0].id
        #expect(await doc.calculateAndWait([id]))
        #expect(doc.results[id] != nil && !doc.isStale(id))
    }

    @MainActor @Test func lateBackgroundResultDoesNotOverwriteNewerOne() async throws {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        let id = doc.project.operations[0].id
        doc.calculate([id])                       // snapshot before the move
        step(um) { doc.translateSelection(by: Vec2(0, 1)) }
        doc.calculateNow([id])                    // fresh result
        try await waitForCalculations(doc)
        #expect(!doc.isStale(id))
    }

    @MainActor @Test func calculateWhileCalculatingQueuesARerun() async throws {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        let id = doc.project.operations[0].id
        doc.calculate([id])
        step(um) { doc.translateSelection(by: Vec2(0, 1)) }
        doc.calculate([id])                       // previously dropped
        try await waitForCalculations(doc)
        #expect(doc.results[id] != nil && !doc.isStale(id))
    }

    @Test func snapshotEmbedsReferencedTools() throws {
        let (doc, um) = makeDoc()
        step(um) { doc.addOperation(.vcarve) }
        let snap = try doc.snapshot(contentType: .loftlineProject)
        #expect(snap.project.tools.map(\.id) == [doc.project.operations[0].setup.toolID])
        let decoded = try LoftLineProject.decode(from: snap.project.encoded())
        #expect(decoded == snap.project)
    }

    @Test func jobSetupChangeConvertsUnitsAndUndoes() {
        let (doc, um) = makeDoc()
        var form = JobSetupForm(document: doc.document)
        form.setUnits(.millimeter)
        step(um) { doc.applyJobSetup(form) }
        #expect(doc.units == .millimeter)
        um.undo()
        #expect(doc.units == .inch)
    }

    @Test func importingUnknownFormatReportsAlert() throws {
        let (doc, _) = makeDoc()
        let url = AppTestSupport.tempDir().appendingPathComponent("x.foo")
        try Data("hello".utf8).write(to: url)
        doc.importFiles([url])
        #expect(doc.alert?.message.contains("cannot import .foo") == true)
    }

    @Test func calculatingProducesToolpathsForPlainRectangles() throws {
        let (doc, um) = makeDoc()
        doc.selectAll()
        step(um) { doc.addOperation(.profile) }
        let id = doc.project.operations[0].id
        doc.calculateNow([id])
        let r = try #require(doc.results[id])
        #expect(r.isOK, "\(r.error ?? "")")
        #expect(r.toolpaths.first?.moves.isEmpty == false)
    }
}

@Suite struct GCodeExporterTests {
    /// Pocket-like toolpath at `x` (separate x values keep footprints apart, so grouping may move them).
    func toolpath(_ tool: Tool, name: String, x: Double = 0) -> Toolpath {
        Toolpath(name: name, kind: .pocket, tool: tool,
                 moves: [.rapid(to: Vec3(x, 0, 0.2)), .linear(to: Vec3(x + 1, 0, -0.1), feed: 50),
                         .rapid(to: Vec3(x + 1, 0, 0.2))])
    }

    @Test func combinedExportGroupsByToolAndSkipsDisabled() {
        let p = AppTestSupport.project()
        let lib = ToolLibrary.seeded
        var ops: [AnyOperation] = []
        var results: [UUID: ToolpathResult] = [:]
        for (i, t) in [lib.tools[0], lib.tools[5], lib.tools[0]].enumerated() {
            var proj = p
            proj.operations = ops
            var op = OperationFactory.make(kind: .profile, project: proj, library: lib, shapeIDs: [])!
            var s = op.editableSetup
            s.toolID = t.id
            op.editableSetup = s
            ops.append(op)
            results[op.id] = ToolpathResult(toolpaths: [toolpath(t, name: "tp\(i)", x: Double(i) * 10)], error: nil, operation: op,
                                            designRevision: 0, estimatedSeconds: 1)
        }
        let grouped = GCodeExporter.toolpaths(scope: .all, operations: ops, results: results, groupByTool: true)
        #expect(grouped.map(\.name) == ["tp0", "tp2", "tp1"])
        let ordered = GCodeExporter.toolpaths(scope: .all, operations: ops, results: results, groupByTool: false)
        #expect(ordered.map(\.name) == ["tp0", "tp1", "tp2"])
        var disabled = ops
        var s = disabled[1].editableSetup
        s.isEnabled = false
        disabled[1].editableSetup = s
        #expect(GCodeExporter.toolpaths(scope: .all, operations: disabled, results: results, groupByTool: true).count == 2)
        #expect(GCodeExporter.toolpaths(scope: .operation(ops[1].id), operations: ops, results: results, groupByTool: true)
            .map(\.name) == ["tp1"])
    }

    @Test func emptyExportExplainsWhy() {
        let r = GCodeExporter.export(project: AppTestSupport.project(), toolpaths: [], profile: BuiltInPosts.avidMach4Inch,
                                     jobName: "x", expected: .notChecked(because: "test"))
        #expect(r.text == nil && r.errorMessage != nil)
    }

    @Test func exportProducesAValidatedProgram() throws {
        let tp = toolpath(ToolLibrary.seeded.tools[0], name: "a")
        let r = GCodeExporter.export(project: AppTestSupport.project(), toolpaths: [tp],
                                     profile: BuiltInPosts.avidMach4Inch, jobName: "Sign", expected: .notChecked(because: "test"))
        #expect(r.errorMessage == nil, Comment(rawValue: r.errorMessage ?? ""))
        let text = try #require(r.text)
        #expect(text.contains("G20") && text.contains("T1 M6") && text.hasSuffix("M30\n"))
        #expect(!r.hasErrors, "\(r.issues)")
        #expect(r.toolpathCount == 1)
    }

    @Test func fileNamesAreSanitised() {
        #expect(GCodeExporter.suggestedFileName(jobName: "My Sign", operationName: "Profile 1/2",
                                                profile: BuiltInPosts.avidMach4Inch) == "My_Sign_Profile_1_2.tap")
        #expect(GCodeExporter.suggestedFileName(jobName: "", operationName: nil,
                                                profile: BuiltInPosts.genericGRBLMM) == "Untitled.nc")
    }

    @Test func materialDescription() {
        #expect(GCodeExporter.materialDescription(Document()) == "24 x 18 x 0.75 in")
    }
}

@Suite struct ToolpathCalculatorTests {
    @Test func durations() {
        #expect(ToolpathCalculator.formatDuration(45) == "45s")
        #expect(ToolpathCalculator.formatDuration(200) == "3m 20s")
        #expect(ToolpathCalculator.formatDuration(3725) == "1h 02m 05s")
    }

    /// A tool-change allowance typed as 1e300 used to trap the formatter (`Int(s.rounded())`) and crash the
    /// sidebar summary, the job sheet and the preview's time text (issue #56).
    @Test func anAbsurdDurationShowsAPlaceholderInsteadOfTrapping() {
        #expect(ToolpathCalculator.formatDuration(1e300) == "over 1,000,000 h")
        #expect(ToolpathCalculator.formatDuration(.infinity) == "over 1,000,000 h")
        #expect(ToolpathCalculator.formatDuration(.nan) == "—")
        #expect(ToolpathCalculator.formatDuration(-.infinity) == "—")
        #expect(ToolpathCalculator.formatDuration(-1e300) == "—")
        #expect(ToolpathCalculator.formatDuration(Double(Int.max)) == "over 1,000,000 h")
        // The largest value shown as a time, and the first that is not.
        #expect(ToolpathCalculator.formatDuration(3_600_000_000) == "1000000h 00m 00s")
        #expect(ToolpathCalculator.formatDuration(3_600_000_001) == "over 1,000,000 h")
        #expect(ToolpathCalculator.formatDuration(0) == "0s")
    }

    @Test func errorsAreDescribed() {
        #expect(ToolpathCalculator.describe(CAMError.noGeometry).contains("Select"))
        #expect(ToolpathCalculator.describe(CAMError.notImplemented("X")).contains("X"))
    }
}

@Suite struct ToolLibraryModelTests {
    @Test func crudPersists() throws {
        let model = AppTestSupport.library()
        let before = model.tools.count
        let t = model.add(kind: .vBit)
        #expect(model.tools.count == before + 1)
        #expect(t.number == 10) // seeded tools use 1...9
        #expect(t.angle == 60)
        var edited = t
        edited.name = "Edited"
        model.update(edited)
        #expect(try model.store.load().tool(id: t.id)?.name == "Edited")
        let dup = model.duplicate(id: t.id)!
        #expect(dup.number == 11 && dup.name == "Edited copy")
        model.delete(id: t.id)
        #expect(try model.store.load().tool(id: t.id) == nil)
    }

    @Test func restoreDefaultsReaddsMissing() {
        let model = AppTestSupport.library()
        let id = model.tools[0].id
        model.delete(id: id)
        model.restoreDefaults()
        #expect(model.library.tool(id: id) != nil)
    }

    @Test func millimetreTemplate() {
        let t = ToolLibraryModel.template(kind: .endMill, units: .millimeter, number: 3)
        #expect(t.units == .millimeter && abs(t.diameter - 6.35) < 1e-9 && t.number == 3)
    }
}

@Suite struct PostProfileStoreTests {
    @Test func userProfilesOverrideBuiltIns() throws {
        let store = PostProfileStore(directory: AppTestSupport.tempDir())
        #expect(store.allProfiles().count == BuiltInPosts.all.count)
        var custom = BuiltInPosts.avidMach4Inch
        custom.name = "Avid (tweaked)"
        _ = try store.save(custom)
        var other = BuiltInPosts.genericGRBLMM
        other.id = "xcarve"
        _ = try store.save(other)
        #expect(store.allProfiles().count == BuiltInPosts.all.count + 1)
        #expect(store.profile(id: custom.id).name == "Avid (tweaked)")
        #expect(store.profile(id: "missing").id == PostProfileStore.defaultProfileID)
    }

    @Test func defaultFollowsUnits() {
        #expect(PostProfileStore.defaultID(for: .millimeter) == BuiltInPosts.avidMach4MM.id)
    }
}

@Suite struct ImportServiceTests {
    @Test func unsupportedFormatThrows() {
        var p = AppTestSupport.project()
        #expect(throws: LoftLineIOError.self) {
            _ = try ImportService.importFile(data: Data(), fileName: "a.xyz", into: &p)
        }
    }

    @Test func meshIsCentredOnMaterial() {
        let mesh = Mesh3D(vertices: [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 4, 0.5)], indices: [0, 1, 2])
        let m = ImportService.place(mesh: mesh, name: "bowl", job: JobSetup())
        #expect(m.offset.isApproximatelyEqual(to: Vec2(11, 7), tolerance: 1e-9))
        #expect(abs(m.depth - 0.5) < 1e-9)
    }
}
