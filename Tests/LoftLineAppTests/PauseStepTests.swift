import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The operator pause from the operation's setup to the program, the job sheet and the stale check.
@Suite struct PauseStepTests {
    /// A document with two profile toolpaths on the same vectors, both calculated.
    func makeDoc() -> (LoftLineDocument, UndoManager, [UUID]) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.selectAll()
        um.beginUndoGrouping(); doc.addOperation(.profile); doc.addOperation(.profile); um.endUndoGrouping()
        let ids = doc.project.operations.map(\.id)
        doc.calculateNow(ids)
        return (doc, um, ids)
    }

    func setPause(_ doc: LoftLineDocument, _ id: UUID, _ pause: PauseStep?) {
        guard var op = doc.operation(id) else { return }
        var s = op.editableSetup
        s.pauseAfter = pause
        op.editableSetup = s
        let o = op
        doc.perform("Pause") { $0.upsertOperation(o) }
    }

    @Test func thePauseRidesOnTheOperationsLastToolpathInACombinedExport() {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(message: "Flip"))
        let all = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        #expect(all.count == 2)
        #expect(all[0].pauseAfter == PauseStep(message: "Flip"))
        #expect(all[1].pauseAfter == nil)
        // A single toolpath's own file is a program on its own: no pause.
        let one = GCodeExporter.toolpaths(scope: .operation(ids[0]), operations: doc.project.operations, results: doc.results, groupByTool: false)
        #expect(one.allSatisfy { $0.pauseAfter == nil })
    }

    @Test func editingThePauseDoesNotMakeTheToolpathStale() {
        let (doc, _, ids) = makeDoc()
        #expect(!doc.isStale(ids[0]))
        setPause(doc, ids[0], PauseStep(message: "Flip"))
        #expect(!doc.isStale(ids[0]))
        setPause(doc, ids[0], PauseStep(message: "Flip again", isOptionalStop: true))
        #expect(!doc.isStale(ids[0]))
        setPause(doc, ids[0], nil)
        #expect(!doc.isStale(ids[0]))
        // Other setup edits still do.
        doc.setOperationEnabled(ids[0], false)
        #expect(doc.isStale(ids[0]))
    }

    @Test func theExportedProgramStopsBetweenTheToolpathsAndValidates() throws {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(message: "Flip the part"))
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        let r = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T")
        let text = try #require(r.text)
        let lines = text.split(separator: "\n").map(String.init)
        let stop = try #require(lines.firstIndex(of: "M0"))
        #expect(lines[stop - 1] == "(MSG, Flip the part)")
        #expect(lines[stop - 2] == "M5")
        let first = try #require(lines.firstIndex { $0.hasPrefix("( Toolpath: Profile 1") })
        let second = try #require(lines.firstIndex { $0.hasPrefix("( Toolpath: Profile 2") })
        #expect(first < stop && stop < second)
        #expect(!r.hasErrors)
        #expect(!r.issues.contains { $0.message.contains("stops") })
    }

    @Test func theJobSheetListsThePauseAndSkipsOneAfterTheLastToolpath() {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(message: "Flip the part"))
        setPause(doc, ids[1], PauseStep(message: "Never written", isOptionalStop: true))
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.steps.map(\.pauseAfter) == ["Flip the part", nil])
        #expect(sheet.pauses == 1)
        let html = JobSheetHTML.render(sheet)
        #expect(html.contains("Pause: Flip the part"))
        #expect(html.contains("· 1 pause<"))
        #expect(!html.contains("Never written"))
    }

    @Test func theJobSheetMarksAnOptionalStop() {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(isOptionalStop: true))
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.steps[0].pauseAfter == "Paused after Profile 1 (optional stop, M1)")
    }

    @Test func onAGRBLPostTheJobSheetSaysTheOptionalStopAlwaysStops() {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(isOptionalStop: true))
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.genericGRBLMM,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.steps[0].pauseAfter == "Paused after Profile 1 (stops, M0: GRBL has no optional stop)")
    }

    @Test func olderProjectsWithoutThePauseKeyStillLoad() throws {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(message: "Flip"))
        let data = try doc.project.encoded()
        var json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"pauseAfter\""))
        let round = try LoftLineProject.decode(from: data)
        #expect(round.operations[0].setup.pauseAfter == PauseStep(message: "Flip"))
        // Strip the key the way an older save would lack it.
        json = json.replacingOccurrences(of: #"(?s)"pauseAfter"\s*:\s*\{.*?\},?"#, with: "", options: .regularExpression)
        let older = try LoftLineProject.decode(from: Data(json.utf8))
        #expect(older.operations[0].setup.pauseAfter == nil)
    }

    @Test func mergingNeverSwallowsAPause() throws {
        // Two same-tool profiles, then a third; a pause after the first.
        let (doc, _, ids) = makeDoc()
        doc.addOperation(.profile)
        var p = doc.project
        p.operations[0].editableSetup.pauseAfter = PauseStep(message: "Add the clamp")
        #expect(p.mergeWithNextProblem(ids[0]) == "This toolpath pauses the machine after it. Turn the pause off to merge it with the next one.")
        #expect(p.mergeWithNext(ids[0]) == nil)
        #expect(p.operations.count == 3)

        // A pause after the second one rides on the merged operation, not on a hidden child.
        p.operations[0].editableSetup.pauseAfter = nil
        p.operations[1].editableSetup.pauseAfter = PauseStep(message: "Flip")
        let mergedID = p.mergeWithNext(ids[0])
        let merged = try #require(mergedID)
        #expect(p.operations[0].setup.pauseAfter == PauseStep(message: "Flip"))
        guard case .merge(let m) = p.operations[0] else { throw Failure.notMerged }
        #expect(m.params.children.allSatisfy { $0.setup.pauseAfter == nil })
        // So the program stops between the merged toolpath and the third one.
        let d2 = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        d2.calculateNow(d2.project.operations.map(\.id))
        let tps = GCodeExporter.toolpaths(scope: .all, operations: d2.project.operations, results: d2.results, groupByTool: false)
        #expect(tps.map { $0.pauseAfter != nil } == [true, false])
        let text = try #require(GCodeExporter.export(project: p, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T").text)
        #expect(text.contains("(MSG, Flip)\nM0\n"))

        // A paused merged operation cannot be merged further either (re-merging flattens its children).
        #expect(p.mergeWithNextProblem(merged) != nil)
        // Splitting gives the pause back to the last part.
        p.splitMerged(merged)
        #expect(p.operations.map { $0.setup.pauseAfter?.message } == [nil, "Flip", nil])
    }

    enum Failure: Error { case notMerged }

    @Test func theSidebarSummaryListsThePauseAndCountsItAsAStop() {
        let (doc, _, ids) = makeDoc()
        setPause(doc, ids[0], PauseStep(message: "Flip the part"))
        setPause(doc, ids[1], PauseStep(message: "Never written"))
        let s = JobSummary.make(operations: doc.project.operations, results: doc.results, groupByTool: false,
                                settings: TimeEstimateSettings(), rapidRate: doc.rapidRateInDocumentUnits, units: doc.units)
        #expect(s.pauses == [JobSummary.PauseRow(after: "Profile 1", text: "Flip the part")])
        #expect(s.toolChanges == 0)
        #expect(s.stops == 1)
        #expect(abs(s.totalSeconds - (s.machiningSeconds + 90)) < 1e-9)
    }

    @Test func anEmptyMessageNamesTheToolpath() {
        #expect(PauseStep().text(afterToolpath: "Pocket 1") == "Paused after Pocket 1")
        #expect(PauseStep(message: "  Flip  ").text(afterToolpath: "Pocket 1") == "Flip")
        #expect(PauseStep(isOptionalStop: true).stopCode == "M1")
    }
}
