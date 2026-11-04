import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Shared setup: Profile (T1) on shape 0, V-Carve (T6) and Pocket (T1) on shape 1, all calculated.
private enum Job {
    static let post = BuiltInPosts.avidMach4Inch

    static func project() -> LoftLineProject {
        var p = AppTestSupport.project()
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        for (kind, ids) in [(OperationKind.profile, [a]), (.vcarve, [b]), (.pocket, [b])] {
            p.operations.append(OperationFactory.make(kind: kind, project: p, library: .seeded, shapeIDs: ids)!)
        }
        return p
    }

    static func results(_ p: LoftLineProject) -> [UUID: ToolpathResult] {
        Dictionary(uniqueKeysWithValues: p.operations.map {
            ($0.id, ToolpathCalculator.calculate($0, project: p, library: .seeded, designRevision: 0, rapidRate: 200))
        })
    }

    /// Motion over a program with the default settings (the fixture owns its model, not the
    /// developer's calibration).
    static let settings = TimeEstimateSettings()
    static func motion(_ tps: [Toolpath]) -> TimeInterval { settings.estimate(tps, rapidRate: 200, units: .inch, toolChanges: false) }
    static func summary(_ p: LoftLineProject, results: [UUID: ToolpathResult]? = nil, groupByTool: Bool,
                        toolChangeSeconds: TimeInterval = 0) -> JobSummary {
        var s = settings
        s.toolChangeSeconds = toolChangeSeconds
        return JobSummary.make(operations: p.operations, results: results ?? Job.results(p), groupByTool: groupByTool,
                               settings: s, rapidRate: 200, units: .inch)
    }
}

@Suite struct JobSummaryTests {
    @Test func groupingNeverPullsAPocketAheadOfOverlappingVCarve() {
        // The pocket (T1) is on the same shape as the V-carve (T6), so it keeps its place.
        let p = Job.project()
        let s = Job.summary(p, groupByTool: true)
        #expect(s.sequence.map(\.number) == [1, 6, 1])
        #expect(s.toolChanges == 2)
    }

    @Test func listOrderChangesToolWheneverItDiffers() {
        let p = Job.project()
        let s = Job.summary(p, groupByTool: false)
        #expect(s.sequence.map(\.number) == [1, 6, 1])
        #expect(s.toolChanges == 2)
    }

    @Test func rowsCarryTimesAndToolsAndTotalSkipsDisabled() {
        var p = Job.project()
        let results = Job.results(p)
        var s = Job.summary(p, results: results, groupByTool: true)
        #expect(s.rows.count == 3)
        #expect(s.rows.allSatisfy { ($0.estimatedSeconds ?? 0) > 0 })
        #expect(s.rows[1].tools.first?.hasPrefix("T6") == true)
        p.operations[1].editableSetup.isEnabled = false
        s = Job.summary(p, results: results, groupByTool: true)
        // The total is the remaining program's motion (its own linking rapids), not a sum of rows.
        let remaining = GCodeExporter.toolpaths(scope: .all, operations: p.operations, results: results, groupByTool: true)
        #expect(abs(s.totalSeconds - Job.motion(remaining)) < 1e-6)
        #expect(s.sequence.map(\.number) == [1])
    }

    @Test func totalAddsTheAllowanceForEachToolChange() {
        // The sidebar total used to leave tool changes out, while the 3D preview counted them.
        let p = Job.project()
        let results = Job.results(p)
        let bare = Job.summary(p, results: results, groupByTool: true)
        let allowed = Job.summary(p, results: results, groupByTool: true, toolChangeSeconds: 90)
        #expect(bare.toolChangeAllowance == 0 && bare.totalSeconds == bare.machiningSeconds)
        #expect(allowed.machiningSeconds == bare.machiningSeconds)
        #expect(allowed.toolChangeAllowance == 2 * 90)  // T1, T6, T1
        #expect(abs(allowed.totalSeconds - (bare.machiningSeconds + 180)) < 1e-6)
    }

    @Test func aToolChangeInsideOneOperationIsCountedOnce() throws {
        // The pocket clears with a 1/2" end mill before its 1/4" finish, so its own estimate
        // already holds one allowance; the job total used to add that change a second time.
        var p = Job.project()
        guard case .pocket(var pocket) = p.operations[2] else { throw TestError.notAPocket }
        pocket.params.clearanceToolIDs = [ToolLibrary.seeded.tools[2].id]
        p.operations[2] = .pocket(pocket)
        let results = Job.results(p)
        #expect(results[p.operations[2].id]!.toolpaths.count == 2)
        var settings = Job.settings
        settings.toolChangeSeconds = 90
        let s = Job.summary(p, results: results, groupByTool: false, toolChangeSeconds: 90)
        #expect(s.sequence.map(\.number) == [1, 6, 3, 1])
        #expect(s.toolChanges == 3)
        // Motion of the program in order plus one allowance per change: three, not four. The
        // program's motion is more than the operations' own, by the rapids that link them, and the
        // total is what the 3D preview shows for the same toolpaths (issue #27).
        let program = GCodeExporter.toolpaths(scope: .all, operations: p.operations, results: results, groupByTool: false)
        let linked = settings.estimate(program, rapidRate: 200, units: .inch, toolChanges: false)
        let separate = p.operations.map { settings.estimate(results[$0.id]!.toolpaths, rapidRate: 200, units: .inch, toolChanges: false) }
            .reduce(0, +)
        #expect(linked > separate + 0.1)
        #expect(abs(s.machiningSeconds - linked) < 1e-6)
        #expect(abs(s.totalSeconds - (linked + 3 * 90)) < 1e-6)
        #expect(abs(s.totalSeconds - settings.estimate(program, rapidRate: 200, units: .inch)) < 1e-6)
        // The pocket's own row still includes its internal change.
        let pocketResult = results[p.operations[2].id]!
        #expect(abs(pocketResult.estimatedSeconds - Job.motion(pocketResult.toolpaths) - 90) < 1e-6)
        #expect(abs((s.rows[2].estimatedSeconds ?? 0) - pocketResult.estimatedSeconds) < 1e-9)
    }

    enum TestError: Error { case notAPocket }

    @Test func nothingCalculatedMeansNoEstimate() {
        // The sidebar read "Estimated time: 0s · No tools" before anything was calculated.
        let p = Job.project()
        #expect(!Job.summary(p, results: [:], groupByTool: true).hasEstimate)
        #expect(Job.summary(p, groupByTool: true).hasEstimate)
    }

    @Test func aSingleToolJobHasNoAllowance() {
        var p = Job.project()
        p.operations[1].editableSetup.isEnabled = false  // the V-carve is the only T6 toolpath
        let s = Job.summary(p, groupByTool: true, toolChangeSeconds: 90)
        #expect(s.toolChanges == 0 && s.toolChangeAllowance == 0)
        #expect(s.totalSeconds == s.machiningSeconds)
    }

    @Test func uncalculatedRowsHaveNoTime() {
        let p = Job.project()
        let s = Job.summary(p, results: [:], groupByTool: true)
        #expect(s.rows.allSatisfy { $0.estimatedSeconds == nil })
        #expect(s.sequence.isEmpty)
        #expect(s.toolChanges == 0)
    }
}

@Suite struct SaveAllToolpathsTests {
    @Test func singleFileModeProducesOneProgram() {
        let p = Job.project()
        let r = Job.results(p)
        for grouped in [true, false] {
            let files = GCodeBatchExport.plan(mode: .oneFile, operations: p.operations, results: r, jobName: "Sign",
                                              profile: Job.post, groupByTool: grouped)
            #expect(files.count == 1)
            #expect(files[0].fileName == "Sign.tap")
        }
    }

    @Test func oneFileFollowsThePreference() {
        // One file is written in the order the preview, the tool-change summary and the job sheet show: the shared
        // group-by-tool preference (docs/implicit-state-machines.md #16).
        let p = Job.project()
        let r = Job.results(p)
        for grouped in [true, false] {
            let file = GCodeBatchExport.plan(mode: .oneFile, operations: p.operations, results: r, jobName: "Sign",
                                             profile: Job.post, groupByTool: grouped)[0]
            let shown = GCodeExporter.toolpaths(scope: .all, operations: p.operations, results: r, groupByTool: grouped)
            #expect(file.toolpaths.map(\.id) == shown.map(\.id))
        }
        #expect(SaveAllMode.allCases == [.oneFile, .filePerToolpath, .filePerTool])
    }

    @Test func filePerToolpathNamesEachAfterItsToolpath() {
        let p = Job.project()
        let files = GCodeBatchExport.plan(mode: .filePerToolpath, operations: p.operations, results: Job.results(p),
                                          jobName: "Sign", profile: Job.post, groupByTool: false)
        #expect(files.map(\.fileName) == ["Sign_Profile_1.tap", "Sign_V-Carve_1.tap", "Sign_Pocket_1.tap"])
    }

    @Test func filePerToolHasNoToolChangesInside() throws {
        let p = Job.project()
        let files = GCodeBatchExport.plan(mode: .filePerTool, operations: p.operations, results: Job.results(p),
                                          jobName: "Sign", profile: Job.post, groupByTool: false)
        // The pocket (T1) overlaps the V-carve (T6), so it keeps its own, later, T1 file.
        #expect(files.count == 3)
        #expect(files.map { $0.toolpaths.map(\.name) } == [["Profile 1"], ["V-Carve 1"], ["Pocket 1"]])
        #expect(files[0].fileName.hasPrefix("01_Sign_T1_"))
        #expect(files[1].fileName.hasPrefix("02_Sign_T6_"))
        #expect(files[2].fileName.hasPrefix("03_Sign_T1_"))
        for f in files { #expect(Set(f.toolpaths.map(\.tool.id)).count == 1) }
        let posted = GCodeBatchExport.post(files, project: p, profile: Job.post, jobName: "Sign", expected: .notChecked(because: "test"))
        let dir = AppTestSupport.tempDir()
        let urls = try GCodeFileSet(posted: posted).write(to: dir)
        #expect(urls.count == 3)
        let text = try String(contentsOf: urls[1], encoding: .utf8)
        #expect(text.contains("M30"))
    }

    @Test func filePerToolNeverPullsAThroughProfileAheadOfOtherTools() {
        // Pocket (T1) → V-carve (T6) → final profile (T1): the profile must stay last.
        var p = AppTestSupport.project()
        let a = p.document.shapes[0].id, b = p.document.shapes[1].id
        for (kind, ids) in [(OperationKind.pocket, [b]), (.vcarve, [b]), (.profile, [a])] {
            p.operations.append(OperationFactory.make(kind: kind, project: p, library: .seeded, shapeIDs: ids)!)
        }
        let files = GCodeBatchExport.plan(mode: .filePerTool, operations: p.operations, results: Job.results(p),
                                          jobName: "Sign", profile: Job.post, groupByTool: false)
        #expect(files.map { $0.toolpaths.map(\.name) } == [["Pocket 1"], ["V-Carve 1"], ["Profile 1"]])
        #expect(files.map(\.title).first?.hasPrefix("1. ") == true)
    }

    @Test func disabledAndUncalculatedToolpathsAreSkipped() {
        var p = Job.project()
        var r = Job.results(p)
        p.operations[0].editableSetup.isEnabled = false
        r[p.operations[2].id] = nil
        let files = GCodeBatchExport.plan(mode: .filePerToolpath, operations: p.operations, results: r,
                                          jobName: "Sign", profile: Job.post, groupByTool: false)
        #expect(files.map(\.title) == ["V-Carve 1"])
    }

    @Test func duplicateFileNamesGetSuffixes() {
        let f = PlannedGCodeFile(fileName: "a.tap", title: "a", toolpaths: [])
        #expect(GCodeBatchExport.uniquified([f, f, f]).map(\.fileName) == ["a.tap", "a_2.tap", "a_3.tap"])
    }
}

@Suite struct ValidationReportTests {
    @Test func hasOneSectionPerEnabledToolpathPlusCombined() {
        let p = Job.project()
        let report = ValidationReport.make(project: p, results: Job.results(p), profile: Job.post, groupByTool: true)
        #expect(report.sections.map(\.title) == ["Profile 1", "V-Carve 1", "Pocket 1", "Combined program"])
        #expect(report.errorCount == 0)
    }

    @Test func uncalculatedAndFailedToolpathsAreReported() {
        var p = Job.project()
        p.operations[0].editableSetup.shapeIDs = []
        let r = Job.results(p).filter { $0.key != p.operations[2].id }
        let report = ValidationReport.make(project: p, results: r, profile: Job.post, groupByTool: true)
        #expect(report.sections[0].issues.first?.message.hasPrefix("Not exported") == true)
        #expect(report.sections[2].issues.first?.message == "Not calculated yet")
        #expect(report.warningCount >= 2)
    }

    @Test func cutsBelowTheSpoilboardAreErrors() {
        var p = Job.project()
        guard case .pocket(var o) = p.operations[2] else { Issue.record("expected pocket"); return }
        o.params.depth.cutDepth = p.document.job.thickness + 0.5
        p.operations[2] = .pocket(o)
        let report = ValidationReport.make(project: p, results: Job.results(p), profile: Job.post, groupByTool: true)
        #expect(report.errorCount > 0)
        #expect(report.sections[2].issues.contains { $0.severity == .error })
    }
}

@Suite struct InlayWizardTests {
    @Test func createsFemalePocketAndMalePlug() {
        let p = AppTestSupport.project()
        var w = InlayWizardModel(project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])
        #expect(w.problems(library: .seeded).isEmpty)
        w.pocketDepth = 0.25; w.plugStartDepth = 0.15; w.glueGap = 0.03
        let ops = w.makeOperations()
        #expect(ops.count == 2)
        guard case .inlay(let f) = ops[0], case .inlay(let m) = ops[1] else { Issue.record("expected inlays"); return }
        #expect(f.params.part == .female && m.params.part == .male)
        #expect(f.setup.name == "Inlay 1 Pocket" && m.setup.name == "Inlay 1 Plug")
        // The plug is cut on another board, so it must not be exported with the pocket by default.
        #expect(f.setup.isEnabled && !m.setup.isEnabled)
        #expect(m.params.maleStartDepth == 0.15 && f.params.pocketDepth == 0.25)
        #expect(f.setup.toolID == ToolLibrary.seeded.tools[5].id)
        #expect(abs(w.bottomGap - 0.1) < 1e-12)
    }

    @Test func rejectsImpossibleDepthsAndMissingVectors() {
        let p = AppTestSupport.project()
        var w = InlayWizardModel(project: p, library: .seeded, shapeIDs: [])
        w.plugStartDepth = 0.2; w.glueGap = 0.05; w.pocketDepth = 0.2
        let problems = w.problems(library: .seeded)
        #expect(problems.count == 2)
        w.vbitID = ToolLibrary.seeded.tools[0].id
        #expect(w.problems(library: .seeded).contains("Inlays need a V-bit."))
    }

    @Test func millimetreDocumentsGetScaledDefaults() {
        let p = AppTestSupport.project().converted(to: .millimeter)
        let w = InlayWizardModel(project: p, library: .seeded, shapeIDs: [])
        #expect(abs(w.pocketDepth - 0.2 * 25.4) < 1e-9)
    }
}

@Suite struct ModelPlacementFormTests {
    /// 4 x 2 base, 1 high pyramid.
    static let mesh = Mesh3D(vertices: [Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(4, 2, 0), Vec3(0, 2, 0), Vec3(2, 1, 1)],
                             indices: [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4, 0, 2, 1, 0, 3, 2])

    static func job() -> JobSetup { Document().job }

    @Test func defaultsCentreTheModelAtNativeSize() {
        let job = Self.job()
        let f = ModelPlacementForm(mesh: Self.mesh, name: "Pyr", job: job, library: .seeded)
        let m = f.placedModel
        #expect(abs(m.scale - 1) < 1e-12)
        #expect(m.footprint.center.distance(to: job.materialBounds.center) < 1e-9)
        #expect(abs(m.depth - min(1, job.thickness)) < 1e-12)
        #expect(m.zTop == 0)
    }

    @Test func sizeKeepsAspectAndPositionAndZAreApplied() {
        var f = ModelPlacementForm(mesh: Self.mesh, name: "Pyr", job: Self.job(), library: .seeded)
        f.setWidth(8)
        #expect(f.height == 4)
        f.setHeight(1)
        #expect(f.width == 2)
        f.position = .custom
        f.x = 3; f.y = 5
        f.zHeight = 0.4; f.zOffset = 0.1
        let m = f.placedModel
        #expect(m.footprint.min.distance(to: Vec2(3, 5)) < 1e-9)
        #expect(abs(m.footprint.width - 2) < 1e-9)
        #expect(abs(m.zTop - 0.1) < 1e-12 && abs(m.depth - 0.5) < 1e-12)
        #expect(f.warnings.isEmpty)
    }

    @Test func oversizedModelsShrinkToFitAndWarnWhenTooDeep() {
        var job = Self.job()
        job.width = 2; job.height = 2
        var f = ModelPlacementForm(mesh: Self.mesh, name: "Pyr", job: job, library: .seeded)
        #expect(abs(f.width - 2) < 1e-9 && abs(f.height - 1) < 1e-9)
        f.zHeight = job.thickness
        f.zOffset = 0.1
        #expect(f.warnings.contains("The model goes deeper than the material thickness."))
    }

    @Test func createsRoughingAndFinishingToolpaths() throws {
        var p = AppTestSupport.project()
        let f = ModelPlacementForm(mesh: Self.mesh, name: "Pyr", job: p.document.job, library: .seeded)
        p.document.models.append(f.placedModel)
        let ops = f.makeOperations(existing: p.operations, units: p.document.units)
        #expect(ops.map(\.setup.name) == ["Pyr Roughing", "Pyr Finishing"])
        guard case .relief3D(let r) = ops[0], case .relief3D(let fin) = ops[1] else { Issue.record("expected 3D"); return }
        #expect(r.params.roughing.isEnabled && !r.params.finishing.isEnabled)
        #expect(!fin.params.roughing.isEnabled && fin.params.finishing.isEnabled)
        #expect(ToolLibrary.seeded.tool(id: r.setup.toolID)?.kind == .endMill)
        #expect(ToolLibrary.seeded.tool(id: fin.setup.toolID)?.kind == .ballNose)
        p.operations = ops
        for op in ops {
            let res = ToolpathCalculator.calculate(op, project: p, library: .seeded, designRevision: 0, rapidRate: 200)
            #expect(res.error == nil)
            #expect(res.toolpaths.count == 1)
        }
    }

    @Test func editingRoundTripsAnExistingModel() {
        var f = ModelPlacementForm(mesh: Self.mesh, name: "Pyr", job: Self.job(), library: .seeded)
        f.setWidth(6); f.zOffset = 0.05; f.zHeight = 0.3
        let m = f.placedModel
        let e = ModelPlacementForm(editing: m, job: Self.job(), library: .seeded)
        #expect(e.modelID == m.id)
        #expect(!e.createToolpaths)
        #expect(e.placedModel == m || e.placedModel.footprint.min.distance(to: m.footprint.min) < 1e-9)
        #expect(abs(e.width - 6) < 1e-9 && abs(e.zHeight - 0.3) < 1e-12)
    }
}

@Suite struct TabEditorTests {
    static func setup() -> (LoftLineProject, Shape) {
        let p = AppTestSupport.project()
        return (p, p.document.shapes[0]) // 2x1 rectangle at (1,1)
    }

    @Test func clickingNearAVectorAddsATabThere() throws {
        let (p, s) = Self.setup()
        let t = try #require(TabEditor.adding(at: Vec2(2, 0.98), to: TabSettings(), shapes: [s], maxDistance: 0.1,
                                              tolerance: 0.001))
        #expect(t.isEnabled && t.isManual && t.manualTabs?.count == 1)
        let pos = TabEditor.positions(t, document: p.document, tolerance: 0.001)
        #expect(pos[0]!.distance(to: Vec2(2, 1)) < 1e-6)
        #expect(TabEditor.adding(at: Vec2(2, 0.5), to: t, shapes: [s], maxDistance: 0.1, tolerance: 0.001) == nil)
    }

    @Test func tabsCanBeHitMovedAndRemoved() throws {
        let (p, s) = Self.setup()
        var t = try #require(TabEditor.adding(at: Vec2(2, 1), to: TabSettings(), shapes: [s], maxDistance: 0.1,
                                              tolerance: 0.001))
        #expect(TabEditor.hit(at: Vec2(2.03, 1.02), tabs: t, document: p.document, radius: 0.05, tolerance: 0.001) == 0)
        #expect(TabEditor.hit(at: Vec2(2.5, 1), tabs: t, document: p.document, radius: 0.05, tolerance: 0.001) == nil)
        t = try #require(TabEditor.moving(0, to: Vec2(3.4, 1.5), in: t, shapes: [s], tolerance: 0.001))
        let q = TabEditor.positions(t, document: p.document, tolerance: 0.001)[0]!
        #expect(q.distance(to: Vec2(3, 1.5)) < 1e-6) // snapped onto the right edge
        t = TabEditor.removing(0, from: t)
        #expect(t.manualTabs == [])
        #expect(t.isManual)
    }

    @Test func switchingToManualSeedsTheAutomaticCount() {
        let (p, _) = Self.setup()
        var tabs = TabSettings(isEnabled: true, countPerPath: 3)
        tabs = TabEditor.makeManual(tabs, shapes: p.document.shapes)
        #expect(tabs.manualTabs?.count == 6)
        #expect(TabEditor.makeAutomatic(tabs).manualTabs == nil)
    }

    @Test func manualTabsReachTheGeneratedToolpath() throws {
        var p = AppTestSupport.project()
        let s = p.document.shapes[0]
        var op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [s.id])!
        let tabs = try #require(TabEditor.adding(at: Vec2(2, 1), to: op.profileTabs!, shapes: [s], maxDistance: 0.1,
                                                 tolerance: 0.001))
        op = op.withProfileTabs(tabs)
        p.operations = [op]
        let r = ToolpathCalculator.calculate(op, project: p, library: .seeded, designRevision: 0, rapidRate: 200)
        #expect(r.error == nil)
        // With tabs the deepest cut is still the full depth, but some final-pass moves are raised.
        let coords = MachineCoordinates(job: p.document.job)
        let tabTop = coords.z(depth: p.document.job.thickness - tabs.thickness)
        #expect(r.toolpaths[0].moves.contains { abs(($0.target?.z ?? 99) - tabTop) < 1e-9 })
    }
}

@Suite struct OperationHintsTests {
    @Test func peckSummaryListsEachPeck() {
        let s = OperationHints.peckSummary(DrillParameters(cutDepth: 0.5, peckDepth: 0.2), units: .inch)
        #expect(s == "3 pecks per hole: 0.2, 0.4, 0.5 in.")
        #expect(OperationHints.peckSummary(DrillParameters(cutDepth: 0.5, peckDepth: 0), units: .inch)
                    .hasPrefix("Single plunge"))
    }

    @Test func fluteLengthProblemNamesTheToolAndItsFlutes() {
        let eighth = ToolLibrary.seeded.tools[1]   // 0.5 in flute
        #expect(OperationHints.fluteLengthProblem(tool: eighth, cutDepth: 0.75, startDepth: 0, units: .inch)
                    == "Deeper than the 0.5000 in flutes of \(eighth.name); the shank will rub the wall above them.")
        #expect(OperationHints.fluteLengthProblem(tool: eighth, cutDepth: 0.5, startDepth: 0, units: .inch) == nil)
        #expect(OperationHints.fluteLengthProblem(tool: nil, cutDepth: 0.75, startDepth: 0, units: .inch) == nil)
        var unknown = eighth; unknown.fluteLength = nil
        #expect(OperationHints.fluteLengthProblem(tool: unknown, cutDepth: 0.75, startDepth: 0, units: .inch) == nil)
        let mm = eighth.converted(to: .millimeter)
        #expect(OperationHints.fluteLengthProblem(tool: mm, cutDepth: 20, startDepth: 0, units: .millimeter)?.contains("12.700 mm flutes") == true)
        var third = eighth; third.fluteLength = 0.3
        #expect(OperationHints.fluteLengthProblem(tool: third, cutDepth: 0.1 + 0.2, startDepth: 0, units: .inch) == nil)
        // Material above the start depth is already gone.
        #expect(OperationHints.fluteLengthProblem(tool: eighth, cutDepth: 0.9, startDepth: 0.5, units: .inch) == nil)
        #expect(OperationHints.fluteLengthProblem(tool: eighth, cutDepth: 1.1, startDepth: 0.5, units: .inch) != nil)
    }

    @Test func clearanceToolMustBeLargerThanFinishTool() {
        let lib = ToolLibrary.seeded
        let quarter = lib.tools[0], eighth = lib.tools[1], half = lib.tools[2]
        #expect(OperationHints.pocketClearanceProblem(finish: quarter, clearance: half) == nil)
        #expect(OperationHints.pocketClearanceProblem(finish: quarter, clearance: eighth) != nil)
        #expect(OperationHints.pocketClearanceProblem(finish: quarter, clearance: quarter) != nil)
        #expect(OperationHints.pocketClearanceProblem(finish: quarter, clearance: nil) == nil)
    }
}
