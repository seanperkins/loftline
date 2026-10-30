import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Warnings for mistakes a valid program hides: loose parts, shared tool numbers, model depth,
/// tool names that disagree with their diameter.
@Suite struct PreflightChecksTests {
    let endMill = ToolLibrary.seeded.tools[0]   // T1 1/4" End Mill

    func project(thickness: Double = 0.75) -> LoftLineProject {
        var p = AppTestSupport.project()   // two closed 2x1 rectangles
        p.document.job.thickness = thickness
        return p
    }

    func profile(_ p: LoftLineProject, name: String = "Cut", depth: Double, tabs: Bool, shapes: [UUID]? = nil) -> AnyOperation {
        var params = ProfileParameters(depth: DepthSettings(cutDepth: depth))
        params.tabs.isEnabled = tabs
        let setup = OperationSetup(name: name, toolID: endMill.id, shapeIDs: shapes ?? p.document.shapes.map(\.id))
        return .profile(ProfileOperation(setup: setup, params: params))
    }

    // MARK: Loose parts

    @Test func aThroughCutWithTabsOffIsALoosePart() {
        let p = project()
        let issues = PreflightChecks.looseParts([profile(p, depth: 0.75, tabs: false)], document: p.document)
        #expect(issues.map(\.message) == [
            "Cut cuts 2 closed vectors through the full 0.75 in with tabs off: the part comes loose while the cutter is still in it. Turn on Tabs, or make sure the part is held another way.",
        ])
        #expect(issues.first?.severity == .warning)
        let one = PreflightChecks.looseParts([profile(p, depth: 0.76, tabs: false, shapes: [p.document.shapes[0].id])], document: p.document)
        #expect(one.first?.message.hasPrefix("Cut cuts 1 closed vector through") == true)
    }

    @Test func tabsOrAShallowerCutAreNotLooseParts() {
        let p = project()
        #expect(PreflightChecks.looseParts([profile(p, depth: 0.75, tabs: true)], document: p.document).isEmpty)
        #expect(PreflightChecks.looseParts([profile(p, depth: 0.7, tabs: false)], document: p.document).isEmpty)
        // Rounding noise at the bottom still counts as through.
        #expect(PreflightChecks.looseParts([profile(p, depth: 0.7499, tabs: false)], document: p.document).count == 1)
    }

    @Test func aLoosePartInsideAMergedOperationIsStillReported() throws {
        // Merge with Next turns two profiles into one operation; the through cut inside it is unchanged.
        let p = project()
        let through = profile(p, name: "Outline", depth: 0.75, tabs: false, shapes: [p.document.shapes[0].id])
        let shallow = profile(p, name: "Groove", depth: 0.2, tabs: false, shapes: [p.document.shapes[1].id])
        let merged = try #require(MergeOperation.merging([shallow, through], name: "Groove + Outline"))
        let issues = PreflightChecks.looseParts([.merge(merged)], document: p.document)
        #expect(issues.map(\.message) == [
            "Outline (in Groove + Outline) cuts 1 closed vector through the full 0.75 in with tabs off: the part comes loose while the cutter is still in it. Turn on Tabs, or make sure the part is held another way.",
        ])
        // And through the whole export path, where the toolpaths point at the merge.
        var project = p
        project.operations = [.merge(merged)]
        let doc = LoftLineDocument(project: project, toolLibrary: AppTestSupport.library())
        doc.calculateNow([merged.setup.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        let all = PreflightChecks.issues(project: doc.project, toolpaths: tps, units: .inch)
        #expect(all.contains { $0.message.hasPrefix("Outline (in Groove + Outline) cuts") })
    }

    @Test func onlyProfilesOfClosedVectorsCount() {
        let p = project()
        let pocket = AnyOperation.pocket(PocketOperation(setup: OperationSetup(name: "P", toolID: endMill.id, shapeIDs: p.document.shapes.map(\.id)),
                                                         params: PocketParameters(depth: DepthSettings(cutDepth: 0.75))))
        #expect(PreflightChecks.looseParts([pocket], document: p.document).isEmpty)
        #expect(PreflightChecks.looseParts([profile(p, depth: 0.75, tabs: false, shapes: [])], document: p.document).isEmpty)
    }

    // MARK: Tool numbers

    @Test func twoToolsWithOneNumberAndDifferentGeometryAreReported() {
        var small = ToolLibrary.seeded.tools[1]   // 1/8" end mill
        small.number = endMill.number
        let issues = PreflightChecks.duplicateToolNumbers([endMill, small])
        #expect(issues.count == 1)
        #expect(issues[0].message == "T1 is 2 different tools in this program: \"1/4\" End Mill (2 flute)\" (end mill, 0.25 in) and \"1/8\" End Mill (2 flute)\" (end mill, 0.125 in). The program says T1 for both, so give one of them another number in the tool database.")
    }

    @Test func aDuplicateLibraryEntryWithTheSameGeometryIsFine() {
        var spare = endMill
        spare.id = UUID()
        spare.name = "Spare 1/4\" End Mill"
        #expect(PreflightChecks.duplicateToolNumbers([endMill, spare]).isEmpty)
        #expect(PreflightChecks.duplicateToolNumbers(ToolLibrary.seeded.tools).isEmpty)
        // The same tool listed twice (two toolpaths) is not a duplicate.
        #expect(PreflightChecks.duplicateToolNumbers([endMill, endMill]).isEmpty)
    }

    // MARK: Names

    static let nameCases: [(String, [Double])] = [
        ("1/4\" End Mill (2 flute)", [0.25]),
        ("1/4 in End Mill", [0.25]),
        ("0.25in Downcut", [0.25]),
        (".125\" Ball", [0.125]),
        ("6mm Downcut", [6.0 / 25.4]),
        ("3.175 mm End Mill", [0.125]),
        ("60° V-Bit 1/2\"", [0.5]),
        ("30° Engraving 0.01\" tip", [0.01]),
        ("1/4 shank 1/8 end mill", [0.25, 0.125]),
        ("2 flute 1/8", [0.125]),
        ("Surfacing bit", []),
        ("#3 center drill", []),
        ("60 deg V", []),
        // Issue #96: a mixed number is one size (1 1/4 in), not the fraction alone.
        ("1-1/4\" Surfacing Bit", [1.25]),
        ("1-1/2 in Spoilboard Cutter", [1.5]),
        ("2-3/8 inch Bit", [2.375]),
        ("2-flute 1/4\" End Mill", [0.25]),
        // The tool library names a 1.25 in cutter "1 1/4 in ...": a spaced mixed number needs its unit.
        ("1 1/4 in 1-flute end mill", [1.25]),
        ("2 3/8\" Ball Nose", [2.375]),
        ("#3 1/4\" Drill", [0.25]),
        ("T3 1/4 in Router", [0.25]),
        // A range keeps both of its fractions; only text read as a mixed number is not read again.
        ("1/8-1/4\" Tapered Ball", [0.125, 0.25]),
    ]

    @Test(arguments: nameCases)
    func readsSizesOutOfNames(name: String, sizes: [Double]) {
        let got = PreflightChecks.sizesInInches(inName: name)
        #expect(got.count == sizes.count, "\(name): \(got)")
        for (a, b) in zip(got, sizes) { #expect(abs(a - b) < 1e-9, "\(name): \(got)") }
    }

    @Test func aNameThatContradictsTheDiameterIsReported() {
        var t = endMill
        t.name = "1/4 in End Mill"
        t.diameter = 0.125
        let issues = PreflightChecks.toolNameMismatches([t])
        #expect(issues.map(\.message) == [
            "Tool T1 is named \"1/4 in End Mill\" but its diameter is 0.125 in: the toolpaths are offset for 0.125 in. Fix the name or the diameter in the tool database.",
        ])
        var mm = endMill
        mm.name = "6mm Downcut"
        mm.units = .millimeter
        mm.diameter = 6.35
        #expect(PreflightChecks.toolNameMismatches([mm]).count == 1)
        mm.diameter = 6
        #expect(PreflightChecks.toolNameMismatches([mm]).isEmpty)
    }

    @Test func namesWithNoSizeAMatchingSizeOrTheTipSizeAreFine() {
        #expect(PreflightChecks.toolNameMismatches(ToolLibrary.seeded.tools).isEmpty)
        var t = endMill
        t.name = "1/4 shank 1/8 end mill"
        t.diameter = 0.125
        #expect(PreflightChecks.toolNameMismatches([t]).isEmpty)
        t.name = "Surfacing bit"
        t.diameter = 1
        #expect(PreflightChecks.toolNameMismatches([t]).isEmpty)
    }

    // MARK: Models

    @Test func aModelBelowTheMaterialBottomIsReported() {
        var p = project(thickness: 0.75)
        p.document.models.append(PlacedModel(name: "Relief", mesh: Mesh3D(), depth: 1.1))
        p.document.models.append(PlacedModel(name: "Shallow", mesh: Mesh3D(), depth: 0.5))
        p.document.models.append(PlacedModel(name: "Exact", mesh: Mesh3D(), depth: 0.75))
        let issues = PreflightChecks.modelsDeeperThanStock(p.document)
        #expect(issues.map(\.message) == [
            "3D model \"Relief\" reaches 1.1 in below the material top, but the material is 0.75 in thick: its toolpaths cut through the bottom. Use thicker material, or give the model less height in Place 3D Model….",
        ])
    }

    // MARK: Through the export

    @Test func theExportCarriesTheWarningsAndStaysValid() {
        let doc = LoftLineDocument(project: project(), toolLibrary: AppTestSupport.library())
        var op = profile(doc.project, depth: 0.75, tabs: false)
        var s = op.editableSetup
        s.shapeIDs = doc.document.shapes.map(\.id)
        op.editableSetup = s
        let o = op
        doc.perform("Add") { $0.operations.append(o) }
        doc.calculateNow([o.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        let r = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: BuiltInPosts.avidMach4Inch, jobName: "T")
        #expect(r.text != nil)
        #expect(!r.hasErrors)
        #expect(r.issues.contains { $0.severity == .warning && $0.message.contains("with tabs off") })
        let sheet = JobSheet.make(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                  groupByTool: false, rapidRate: 600, settings: TimeEstimateSettings())
        #expect(sheet.warnings.contains { $0.contains("with tabs off") })
    }

    @Test func aSecondToolOnAnM0PostWarnsToSplitTheFile() throws {
        let doc = LoftLineDocument(project: project(), toolLibrary: AppTestSupport.library())
        var op = profile(doc.project, depth: 0.25, tabs: false)
        var s = op.editableSetup
        s.shapeIDs = doc.document.shapes.map(\.id)
        op.editableSetup = s
        let o = op
        doc.perform("Add") { $0.operations.append(o) }
        doc.calculateNow([o.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        var second = try #require(tps.first)
        second.id = UUID()
        second.tool = try #require(AppTestSupport.library().tools.first { $0.id != second.tool.id && $0.diameter == second.tool.diameter }
                                   ?? AppTestSupport.library().tools.first { $0.id != second.tool.id })
        let split = { (r: GCodeExportResult) in r.issues.contains { $0.severity == .warning && $0.message.contains("one file per tool") } }
        let linux = GCodeExporter.export(project: doc.project, toolpaths: tps + [second], profile: BuiltInPosts.linuxCNCInch, jobName: "T")
        #expect(split(linux))
        let avid = GCodeExporter.export(project: doc.project, toolpaths: tps + [second], profile: BuiltInPosts.avidMach4Inch, jobName: "T")
        #expect(!split(avid))
        let one = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: BuiltInPosts.linuxCNCInch, jobName: "T")
        #expect(!split(one))
    }

    @Test func aPostThatWouldDwellInTheWrongUnitIsRefusedWithItsReason() throws {
        let doc = LoftLineDocument(project: project(thickness: 0.25), toolLibrary: AppTestSupport.library())
        let op = profile(doc.project, depth: 0.1, tabs: false)
        doc.perform("Add") { $0.operations.append(op) }
        doc.calculateNow([op.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        var post = BuiltInPosts.avidMach4Inch
        post.id = "shop-grbl"
        post.controller = .grbl
        post.dwell = "G4 P{MILLISECONDS}"
        let r = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: post, jobName: "T")
        #expect(r.text == nil)
        #expect(r.errorMessage?.contains("cannot be used") == true && r.errorMessage?.contains("seconds") == true)
        var long = try #require(tps.first)
        long.moves.append(.dwell(seconds: 4000))
        let d = GCodeExporter.export(project: doc.project, toolpaths: [long], profile: BuiltInPosts.avidMach4Inch, jobName: "T")
        #expect(d.text == nil)
        #expect(d.errorMessage?.contains("dwells 4000 s") == true)
        // A drill dwell far past Int.max is refused with its message, not a crash while formatting it.
        var huge = try #require(tps.first)
        huge.moves.append(.dwell(seconds: 1e20))
        let h = GCodeExporter.export(project: doc.project, toolpaths: [huge], profile: BuiltInPosts.avidMach4Inch, jobName: "T")
        #expect(h.text == nil && h.errorMessage?.contains("more than the 3600 s") == true)
    }

    @Test func anOthermillSetupErrorStillWritesAProgramToSaveAnyway() throws {
        var p = project(thickness: 0.25)
        p.document.job.zZero = .spoilboard
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let op = profile(doc.project, depth: 0.1, tabs: false)
        doc.perform("Add") { $0.operations.append(op) }
        doc.calculateNow([op.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        let r = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: BuiltInPosts.othermillInch, jobName: "T")
        #expect(r.text != nil)
        #expect(r.issues.contains { $0.severity == .error && $0.message.contains("material top") })
    }

    /// #119: a program past the bed is one error per axis (the written program's), and Save Anyway still has a program.
    @Test func aCutPastTheBedIsOneErrorAndSaveAnywayWrites() throws {
        let doc = LoftLineDocument(project: project(), toolLibrary: AppTestSupport.library())
        let op = profile(doc.project, depth: 0.1, tabs: false)   // the second rectangle reaches past X7
        doc.perform("Add") { $0.operations.append(op) }
        doc.calculateNow([op.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        var small = BuiltInPosts.avidMach4Inch
        small.limits.xTravel = 5.5
        let r = GCodeExporter.export(project: doc.project, toolpaths: tps, profile: small, jobName: "T")
        #expect(r.text != nil)
        #expect(r.issues.filter { $0.severity == .error && $0.message.hasPrefix("X travel") }.count == 1, "\(r.issues)")
        #expect(!r.issues.contains { $0.message.hasPrefix("Y travel") })
    }

    func exportOneTool(_ post: PostProfile) -> GCodeExportResult {
        let doc = LoftLineDocument(project: project(), toolLibrary: AppTestSupport.library())
        let op = profile(doc.project, depth: 0.1, tabs: false)
        doc.perform("Add") { $0.operations.append(op) }
        doc.calculateNow([op.id])
        let tps = GCodeExporter.toolpaths(scope: .all, operations: doc.project.operations, results: doc.results, groupByTool: false)
        return GCodeExporter.export(project: doc.project, toolpaths: tps, profile: post, jobName: "T")
    }

    /// #128: a post whose pause never stops is refused at export, even for a one-tool job with no pause.
    @Test func aPostWhosePauseNeverStopsIsRefusedAtExport() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "my-stop-post"
        p.pause = ["M5", "(MSG, {MESSAGE})"]
        let r = exportOneTool(try PostProfile.fromJSON(p.toJSON()))
        #expect(r.text == nil)
        let message = try #require(r.errorMessage)
        #expect(message.hasPrefix("The post \"\(p.name)\" cannot be used: posting the post editor's two-tool sample, the pause does not stop"), "\(message)")
        #expect(message.hasSuffix("Fix it in Toolpaths ▸ Post Processors."), "\(message)")
    }

    @Test func aPostTheBuilderRefusesKeepsTheBuildersMessage() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "my-stop-post"
        p.toolChange = ["M5", "{TOOL_NAME}", "M0"]
        let r = exportOneTool(try PostProfile.fromJSON(p.toJSON()))
        #expect(r.text == nil && r.errorMessage?.contains("{TOOL_NAME} is text") == true, "\(r.errorMessage ?? "")")
    }
}

/// A tool named by the library's own naming is never reported as a mismatch against its own diameter.
@Test(arguments: [0.25, 0.125, 1.25, 1.5, 2.375, 0.0625, 3.0])
func aToolNamedByTheLibraryMatchesItsDiameter(diameter: Double) {
    var t = Tool(name: "x", kind: .endMill, number: 1, diameter: diameter, stepdown: 0.1, stepover: 0.1, feedRate: 100, plungeRate: 30)
    t.name = ToolNaming.name(for: t)
    #expect(PreflightChecks.toolNameMismatches([t]).isEmpty, "\(t.name)")
}
