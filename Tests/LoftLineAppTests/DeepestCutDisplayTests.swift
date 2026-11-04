import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The deepest cut is shown wherever a program is handed over: the Export sheet (DeepestCutTests),
/// Save All Toolpaths and the job sheet.
@Suite struct DeepestCutDisplayTests {
    /// A profile through 0.75 in material and a 0.25 in pocket, calculated.
    func calculatedDoc() -> LoftLineDocument {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let lib = ToolLibrary.seeded
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        p.operations = [
            OperationFactory.make(kind: .pocket, project: p, library: lib, shapeIDs: [a])!,
            OperationFactory.make(kind: .profile, project: p, library: lib, shapeIDs: [b])!,
        ]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        return doc
    }

    @Test func theJobSheetStatesTheDeepestCut() {
        let doc = calculatedDoc()
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.deepestCut == "Z -0.75 in (at the material bottom)")
        #expect(JobSheetHTML.render(sheet).contains("<tr><td>Deepest cut</td><td>Z -0.75 in (at the material bottom)</td></tr>"))
    }

    @Test func theJobSheetAgreesWithTheProgramInSpoilboardMode() throws {
        let doc = calculatedDoc()
        var p = doc.project
        p.document.job.zZero = .spoilboard
        let spoil = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        spoil.calculateNow(spoil.project.operations.map(\.id))
        let sheet = JobSheet.make(project: spoil.project, results: spoil.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.deepestCut == "Z 0 in (at the material bottom)")
        // The same number the Export sheet reads back out of the posted program.
        let tps = GCodeExporter.toolpaths(scope: .all, operations: spoil.project.operations, results: spoil.results, groupByTool: false)
        let r = GCodeExporter.export(project: spoil.project, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T", expected: .notChecked(because: "test"))
        #expect(try #require(r.deepestCut).text(units: .inch) == sheet.deepestCut)
    }

    @Test func everySaveAllFileCarriesItsOwnDeepestCut() throws {
        let doc = calculatedDoc()
        let files = GCodeBatchExport.plan(mode: .filePerToolpath, operations: doc.project.operations, results: doc.results,
                                          jobName: "T", profile: BuiltInPosts.avidMach4Inch, groupByTool: false)
        let posted = GCodeBatchExport.post(files, project: doc.project, profile: BuiltInPosts.avidMach4Inch, jobName: "T", expected: .notChecked(because: "test"))
        #expect(posted.count == 2)
        let texts = try posted.map { try #require($0.result.deepestCut).text(units: .inch) }
        #expect(texts == ["Z -0.25 in (0.5 in above the material bottom)", "Z -0.75 in (at the material bottom)"])
    }

    @Test func anEmptyJobHasNoDeepestCut() {
        let p = AppTestSupport.project()
        let sheet = JobSheet.make(project: p, results: [:], profile: BuiltInPosts.avidMach4Inch, groupByTool: false, rapidRate: 600,
                                  settings: TimeEstimateSettings())
        #expect(sheet.deepestCut.isEmpty)
        #expect(!JobSheetHTML.render(sheet).contains("Deepest cut"))
    }
}
