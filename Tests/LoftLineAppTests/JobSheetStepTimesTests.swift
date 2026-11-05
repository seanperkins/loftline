import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The job sheet's step times and its total come from one model: the user's time-estimate settings (issue #55).
@Suite struct JobSheetStepTimesTests {
    /// A pocket and a profile, calculated (the factory gives both the same end mill).
    func calculatedDoc() throws -> LoftLineDocument {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let lib = ToolLibrary.seeded
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        p.operations = [
            try #require(OperationFactory.make(kind: .pocket, project: p, library: lib, shapeIDs: [a])),
            try #require(OperationFactory.make(kind: .profile, project: p, library: lib, shapeIDs: [b])),
        ]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        return doc
    }

    func sheet(_ doc: LoftLineDocument, _ settings: TimeEstimateSettings) -> JobSheet {
        JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                      groupByTool: false, rapidRate: 600, settings: settings)
    }

    @Test func eachStepIsTimedWithTheSettingsTheTotalUses() throws {
        let doc = try calculatedDoc()
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        #expect(tps.count >= 2)
        var calibrated = TimeEstimateSettings()
        calibrated.scale = 2
        for settings in [TimeEstimateSettings(), calibrated] {
            let made = sheet(doc, settings)
            #expect(made.steps.count == tps.count)
            for (step, tp) in zip(made.steps, tps) {
                // One toolpath on its own, without the allowance for a tool change.
                let seconds = settings.estimate([tp], rapidRate: 600, units: .inch, toolChanges: false)
                #expect(step.time == ToolpathCalculator.formatDuration(seconds), "\(step.name)")
            }
        }
        // The calibration scale reaches the steps, as it reaches the total.
        #expect(sheet(doc, TimeEstimateSettings()).steps.map(\.time) != sheet(doc, calibrated).steps.map(\.time))
    }

    @Test func theSheetSaysWhatTheTotalHoldsBeyondTheSteps() throws {
        let doc = try calculatedDoc()
        let html = JobSheetHTML.render(sheet(doc, TimeEstimateSettings()))
        #expect(html.contains("Each time is that toolpath timed on its own, from a standstill."))
        #expect(html.contains("so it is not the sum of this column."))
    }

    /// Why the sheet does not claim the total is above the column: toolpaths that follow on without a stop share
    /// speed across the join, and one timed alone starts and ends at rest.
    @Test func theTotalCanBeBelowTheSumOfTheSteps() {
        let tool = ToolLibrary.seeded.tools[0]
        func run(from: Double, to: Double) -> Toolpath {
            Toolpath(name: "run", kind: .profile, tool: tool,
                     moves: [.linear(to: Vec3(from, 0, 0), feed: 600), .linear(to: Vec3(to, 0, 0), feed: 600)])
        }
        let a = run(from: 0, to: 30), b = run(from: 30, to: 60)
        let settings = TimeEstimateSettings()
        let total = settings.estimate([a, b], rapidRate: 600, units: .inch, toolChanges: false)
        let steps = settings.estimate([a], rapidRate: 600, units: .inch, toolChanges: false)
            + settings.estimate([b], rapidRate: 600, units: .inch, toolChanges: false)
        #expect(total < steps - 0.3, "\(total) against \(steps)")
    }
}
