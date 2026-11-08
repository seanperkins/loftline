import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The sidebar total through the app's own wiring (issue #27): the document's motion estimate over
/// the program the summary orders, against the 3D preview's estimate of the same toolpaths.
@Suite struct JobSummaryWiringTests {
    /// A document with a profile and a pocket on one rectangle and a pocket on the other, the first
    /// pocket on a different tool, so the program has stops and grouping by tool reorders it; all calculated.
    @MainActor
    private func makeDoc(units: LengthUnit) -> LoftLineDocument {
        var p = AppTestSupport.project()
        if units == .millimeter {
            p.document.units = .millimeter
            p.document.job = JobSetup(width: 600, height: 450, thickness: 18, safeZ: 5, homeZ: 20)
            p.document.shapes = p.document.shapes.map { $0.transformed(.scale(25.4, 25.4)) }
        }
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        // The first two on one rectangle, the third on the other: a pocket, since grouping by tool
        // never moves a profile, that can join the first tool's group.
        doc.setSelection([p.document.shapes[0].id])
        doc.addOperation(.profile); doc.addOperation(.pocket)
        doc.setSelection([p.document.shapes[1].id])
        doc.addOperation(.pocket)
        var pocket = doc.project.operations[1]
        var setup = pocket.editableSetup
        setup.toolID = ToolLibrary.seeded.tools[1].id   // 1/8 in end mill; the profile keeps the 1/4 in
        pocket.editableSetup = setup
        let changed = pocket
        doc.perform("Tool") { $0.upsertOperation(changed) }
        doc.calculateNow(doc.project.operations.map(\.id))
        return doc
    }

    @MainActor
    @Test(arguments: [LengthUnit.inch, .millimeter], [true, false])
    func sidebarTotalMatchesThePreviewsEstimate(units: LengthUnit, groupByTool: Bool) {
        let doc = makeDoc(units: units)
        let settings = TimeEstimateSettings.load()
        #expect(doc.results.count == 3 && doc.results.values.allSatisfy(\.isOK))
        let s = doc.jobSummary(groupByTool: groupByTool, settings: settings)
        // In order: T1, T2, T1 (two stops); grouped by tool the second pocket joins the first group.
        #expect(s.sequence.map(\.number) == (groupByTool ? [1, 2] : [1, 2, 1]))
        #expect(s.stops == (groupByTool ? 1 : 2) && s.toolChangeAllowance == Double(s.stops) * settings.toolChangeSeconds)
        // What the preview shows for "All Toolpaths": the same list, timed with the post's rapid rate
        // in document units and the tool-change allowance.
        let shown = PreviewScope.all.toolpaths(operations: doc.outputProject.operations, results: doc.results,
                                               hidden: [], selected: nil, groupByTool: groupByTool)
        let preview = settings.estimate(shown, rapidRate: SimulationPreviewView.rapidRate(for: doc.postProfile, units: doc.units),
                                        units: doc.units)
        #expect(s.machiningSeconds > 0)
        #expect(abs(s.totalSeconds - preview) < 1e-6, "\(units) grouped \(groupByTool): \(s.totalSeconds) vs \(preview)")
        // The program's motion is more than the operations' own by the rapids between them.
        let separate = doc.results.values.map {
            settings.estimate($0.toolpaths, rapidRate: doc.rapidRateInDocumentUnits, units: doc.units, toolChanges: false)
        }.reduce(0, +)
        #expect(s.machiningSeconds > separate)
        // The job sheet, which reads the grouping from the defaults, prints the same total.
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: GCodeExporter.groupByToolKey)
        defaults.set(groupByTool, forKey: GCodeExporter.groupByToolKey)
        defer { if let saved { defaults.set(saved, forKey: GCodeExporter.groupByToolKey) } else { defaults.removeObject(forKey: GCodeExporter.groupByToolKey) } }
        let sheet = doc.makeJobSheet(settings: settings)
        #expect(sheet.totalTime == ToolpathCalculator.formatDuration(s.totalSeconds) && sheet.toolChanges == s.toolChanges)
    }

    @MainActor
    @Test func summaryIsRebuiltOnlyWhenItsInputsChange() {
        let doc = makeDoc(units: .inch)
        let memo = JobSummary.Memo()
        // One input changes per step; the others keep the value they had on the step before.
        var groupByTool = false, settings = TimeEstimateSettings(), rapid = 200.0
        func summary() -> JobSummary {
            memo.summary(operations: doc.outputProject.operations, results: doc.results, groupByTool: groupByTool,
                         settings: settings, rapidRate: rapid, units: .inch)
        }
        let first = summary()
        #expect(summary() == first && memo.builds == 1)
        groupByTool = true
        _ = summary()
        #expect(memo.builds == 2)
        settings.toolChangeSeconds += 1
        _ = summary()
        #expect(memo.builds == 3)
        rapid = 300
        _ = summary()
        #expect(memo.builds == 4)
        // A recalculation replaces the toolpaths, so the summary is rebuilt.
        doc.calculateNow(doc.project.operations.map(\.id))
        _ = summary()
        #expect(memo.builds == 5)
        // So does a settings refresh, which rewrites the row estimates in place.
        let id = doc.project.operations[0].id
        doc.results[id]?.estimatedSeconds += 1
        _ = summary()
        #expect(memo.builds == 6)
        // And an edit to an operation that leaves its toolpaths as they were.
        var renamed = doc.project.operations[0]
        var setup = renamed.editableSetup
        setup.name += " again"
        renamed.editableSetup = setup
        let edited = renamed
        doc.perform("Rename") { $0.upsertOperation(edited) }
        _ = summary()
        #expect(memo.builds == 7)
        _ = summary()
        #expect(memo.builds == 7)
    }
}
