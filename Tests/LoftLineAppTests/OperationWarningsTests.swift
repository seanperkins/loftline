import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Settings mistakes shown in the toolpath form before the export validator would catch them (issue #24).
@Suite struct OperationWarningsTests {
    let post = BuiltInPosts.avidMach4Inch

    /// A 0.75 in job with a profile on the first rectangle (0.5 in deep), and the library it cuts with.
    func setup(units: LengthUnit = .inch) throws -> (project: LoftLineProject, op: AnyOperation, library: ToolLibrary) {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let library = AppTestSupport.library().library
        let op = try #require(OperationFactory.make(kind: .profile, project: p, library: library, shapeIDs: [p.document.shapes[0].id]))
        p.operations = [op]
        return (p, op, library)
    }

    func warnings(_ op: AnyOperation, _ project: LoftLineProject, _ library: ToolLibrary, profile: PostProfile? = nil, units: LengthUnit = .inch) -> [String] {
        OperationWarnings.make(op, project: project, library: library, profile: profile ?? post, units: units)
    }

    func profile(_ op: AnyOperation, depth: Double? = nil, start: Double = 0, tabs: TabSettings? = nil) -> AnyOperation {
        guard case .profile(var o) = op else { return op }
        if let depth { o.params.depth.cutDepth = depth }
        o.params.depth.startDepth = start
        if let tabs { o.params.tabs = tabs }
        return .profile(o)
    }

    @Test func aPlainOperationHasNoWarnings() throws {
        let (p, op, lib) = try setup()
        #expect(warnings(profile(op, depth: 0.5), p, lib).isEmpty)
    }

    @Test func aCutPastTheSpoilboardAllowanceIsReportedButAThroughCutIsNot() throws {
        let (p, op, lib) = try setup()
        let allowance = post.limits.maxSpoilboardCut
        #expect(warnings(profile(op, depth: 0.75), p, lib).isEmpty)                         // through
        #expect(warnings(profile(op, depth: 0.75 + allowance), p, lib).isEmpty)             // as far as the machine allows
        let deep = warnings(profile(op, depth: 0.75 + allowance + 0.1), p, lib)
        #expect(deep.count == 1 && deep[0].contains("below the material bottom") && deep[0].contains("0.75"))
        // The allowance is the post's (machine's), not a constant.
        var generous = post
        generous.limits.maxSpoilboardCut = 0.5
        #expect(warnings(profile(op, depth: 1.2), p, lib, profile: generous).isEmpty)
        #expect(!warnings(profile(op, depth: 1.3), p, lib, profile: generous).isEmpty)
        // A cut projected onto a 3D model is measured from its surface, not the material top.
        guard case .profile(var projected) = op else { return }
        projected.setup.projectOntoModelID = UUID()
        projected.params.depth.cutDepth = 5
        #expect(warnings(.profile(projected), p, lib).isEmpty)
    }

    @Test func aNegativeAllowanceIsTheValidatorsRuleToo() throws {
        let (p, op, lib) = try setup()
        var strict = post
        strict.limits.maxSpoilboardCut = -0.05          // cuts must stop 0.05 in above the bottom
        let through = warnings(profile(op, depth: 0.75), p, lib, profile: strict)
        #expect(through.count == 1 && through[0].contains("below the material bottom") && through[0].contains("0.05 in above the bottom"))
        let above = warnings(profile(op, depth: 0.74), p, lib, profile: strict)
        #expect(above.count == 1 && above[0].contains("above the material bottom") && !above[0].contains("-"))
        #expect(warnings(profile(op, depth: 0.7), p, lib, profile: strict).isEmpty)
    }

    @Test func everyKindWithOneCutDepthIsChecked() throws {
        let (p, _, lib) = try setup()
        let id = p.document.shapes[0].id
        var checked = 0
        for kind in [OperationKind.pocket, .drill, .holeMill, .engrave, .fluting] {
            guard var op = OperationFactory.make(kind: kind, project: p, library: lib, shapeIDs: [id]) else { continue }
            switch op {
            case .pocket(var o): o.params.depth.cutDepth = 3; op = .pocket(o)
            case .drill(var o): o.params.cutDepth = 3; op = .drill(o)
            case .holeMill(var o): o.params.cutDepth = 3; op = .holeMill(o)
            case .engrave(var o): o.params.depth.cutDepth = 3; op = .engrave(o)
            case .fluting(var o): o.params.depth.cutDepth = 3; op = .fluting(o)
            default: continue
            }
            #expect(warnings(op, p, lib).contains { $0.contains("below the material bottom") }, "\(kind)")
            checked += 1
        }
        #expect(checked == 5)
        // A chamfer: its tip depth is the start depth plus how far the tip goes.
        var q = p
        let vbit = try #require(lib.tools.first { $0.kind == .vBit })
        q.tools = [vbit]
        let made = try #require(OperationFactory.make(kind: .chamfer, project: q, library: lib, shapeIDs: [id]))
        guard case .chamfer(var c) = made else { Issue.record("not a chamfer"); return }
        c.setup.toolID = vbit.id
        c.params = ChamferParameters(depth: 0.2, startDepth: 0.7)
        #expect(warnings(.chamfer(c), q, lib).contains { $0.contains("below the material bottom") })
        c.params = ChamferParameters(depth: 0.2, startDepth: 0.4)
        #expect(!warnings(.chamfer(c), q, lib).contains { $0.contains("below the material bottom") })
    }

    @Test func aMillimetreDocumentIsJudgedInMillimetres() throws {
        var (p, op, lib) = try setup()
        p.document.units = .millimeter
        p.document.job.thickness = 19
        // The same Avid inch post: its allowance is converted to mm.
        let allowanceMM = post.limits.maxSpoilboardCut * 25.4
        #expect(warnings(profile(op, depth: 19 + allowanceMM - 0.01), p, lib, units: .millimeter).filter { $0.contains("below") }.isEmpty)
        #expect(warnings(profile(op, depth: 19 + allowanceMM + 1), p, lib, units: .millimeter).contains { $0.contains("below the material bottom") })
    }

    @Test func aToolWithNoFeedPlungeOrDiameterIsReportedUntilTheOverrideFixesIt() throws {
        let (p, op, lib) = try setup()
        var broken = lib
        var tool = try #require(broken.tool(id: op.setup.toolID))
        tool.feedRate = 0; tool.plungeRate = -1; tool.diameter = 0
        broken.upsert(tool)
        let w = warnings(op, p, broken)
        #expect(w.contains { $0.contains("diameter") } && w.contains { $0.contains("feed rate") } && w.contains { $0.contains("plunge rate") })
        guard case .profile(var o) = op else { return }
        o.setup.toolOverride = ToolOverride(feedRate: 50, plungeRate: 20)
        let overridden = warnings(.profile(o), p, broken)
        #expect(overridden.count == 1 && overridden[0].contains("diameter"))
        // Not warned about when the numbers are fine, nor for a merge (it has no tool of its own).
        #expect(warnings(op, p, lib).isEmpty)
    }

    @Test func theSpindleSpeedIsJudgedAgainstThePostsRangeNotAConstant() throws {
        let (p, op, lib) = try setup()
        var fast = lib
        var tool = try #require(fast.tool(id: op.setup.toolID))
        tool.spindleRPM = 30000
        fast.upsert(tool)
        let w = warnings(op, p, fast)
        #expect(w.count == 1 && w[0].contains("30000") && w[0].contains(post.name))
        #expect(w[0].contains("\(Int(post.minRPM))") && w[0].contains("\(Int(post.maxRPM))"))
        var wide = post
        wide.minRPM = 1000; wide.maxRPM = 40000; wide.name = "Big spindle"
        #expect(warnings(op, p, fast, profile: wide).isEmpty)
        tool.spindleRPM = 500
        fast.upsert(tool)
        #expect(warnings(op, p, fast, profile: wide).count == 1)
        // The helper the Tool Database shares.
        #expect(OperationWarnings.rpmProblem(18000, profile: post) == nil)
        #expect(OperationWarnings.rpmProblem(0, profile: post) != nil)
        #expect(OperationWarnings.rpmProblem(.nan, profile: post) != nil)
        // A per-toolpath override counts.
        guard case .profile(var o) = op else { return }
        o.setup.toolOverride = ToolOverride(spindleRPM: 40000)
        #expect(warnings(.profile(o), p, lib).count == 1)
    }

    @Test func aTabAsTallAsTheCutIsReported() throws {
        let (p, op, lib) = try setup()
        let ok = TabSettings(isEnabled: true, length: 0.25, thickness: 0.125)
        #expect(warnings(profile(op, depth: 0.5, tabs: ok), p, lib).isEmpty)
        let tall = TabSettings(isEnabled: true, length: 0.25, thickness: 0.5)
        #expect(warnings(profile(op, depth: 0.5, tabs: tall), p, lib).contains { $0.contains("tab height") && $0.contains("as tall as the cut") && $0.contains("tabs this tall leave nothing cut") })
        #expect(warnings(profile(op, depth: 0.4, tabs: ok), p, lib).isEmpty)
        // The cut is measured from the start depth.
        #expect(warnings(profile(op, depth: 0.5, start: 0.45, tabs: ok), p, lib).contains { $0.contains("tabs") })
        // Manual placement with no anchor has no tab to cut: nothing to say.
        var manual = tall
        manual.manualTabs = []
        #expect(warnings(profile(op, depth: 0.5, tabs: manual), p, lib).isEmpty)
        manual.manualTabs = [TabAnchor(shapeID: p.document.shapes[0].id, fraction: 0.5)]
        #expect(!warnings(profile(op, depth: 0.5, tabs: manual), p, lib).isEmpty)
        // An anchor on a vector that is gone or not selected places no tab, and automatic tabs need a closed vector.
        manual.manualTabs = [TabAnchor(shapeID: UUID(), fraction: 0.5)]
        #expect(warnings(profile(op, depth: 0.5, tabs: manual), p, lib).isEmpty)
        var open = p
        let line = Shape(layerID: open.document.defaultLayerID, paths: [Path(points: [Vec2(0, 0), Vec2(2, 0)], closed: false)])
        open.document.add(line)
        guard case .profile(var onLine) = profile(op, depth: 0.5, tabs: tall) else { return }
        onLine.setup.shapeIDs = [line.id]
        #expect(warnings(.profile(onLine), open, lib).allSatisfy { !$0.contains("tabs") })
        onLine.setup.shapeIDs = [line.id, p.document.shapes[0].id]
        #expect(warnings(.profile(onLine), open, lib).contains { $0.contains("tabs") })
        manual.manualTabs = [TabAnchor(shapeID: line.id, fraction: 0.5)]
        onLine.params.tabs = manual
        #expect(warnings(.profile(onLine), open, lib).allSatisfy { !$0.contains("tabs") })     // an open path has no tab
        // Tabs that are off say nothing.
        var off = tall
        off.isEnabled = false
        #expect(warnings(profile(op, depth: 0.5, tabs: off), p, lib).isEmpty)
    }

    @Test func theOtherToolsAnOperationCutsWithAreJudgedTooAndNamed() throws {
        let (p, _, lib) = try setup()
        var broken = lib
        let finish = try #require(lib.tools.first { $0.kind == .endMill })
        var big = try #require(lib.tools.first { $0.kind == .endMill && $0.diameter > finish.diameter + 1e-9 })   // a clearance tool is the larger one
        big.feedRate = 0; big.spindleRPM = 40000
        broken.upsert(big)
        let id = p.document.shapes[0].id
        var pocket = try #require(OperationFactory.make(kind: .pocket, project: p, library: broken, shapeIDs: [id]))
        guard case .pocket(var o) = pocket else { return }
        o.setup.toolID = finish.id
        o.params.clearanceToolIDs = [big.id]
        pocket = .pocket(o)
        let w = warnings(pocket, p, broken)
        #expect(w.count == 2 && w.allSatisfy { $0.hasPrefix("\(big.name): ") })
        #expect(w.contains { $0.contains("feed rate") } && w.contains { $0.contains("40000") })
        // The toolpath's override is for its primary tool, so the clearance tool's message does not offer it.
        #expect(w.first { $0.contains("feed rate") }?.contains("override") == false)
        // The same tool as the primary one is judged once; a missing tool is the picker's business.
        o.params.clearanceToolIDs = [finish.id, UUID()]
        #expect(warnings(.pocket(o), p, broken).isEmpty)
        // V-carve, inlay and relief name theirs too.
        let vbit = try #require(lib.tools.first { $0.kind == .vBit })
        var slow = broken
        var fixed = big
        fixed.spindleRPM = 18000
        slow.upsert(fixed)
        let vcarve = VCarveOperation(setup: OperationSetup(name: "V", toolID: vbit.id, shapeIDs: [id]),
                                     params: VCarveParameters(flatDepth: 0.2, flatClearanceToolID: big.id))
        #expect(warnings(.vcarve(vcarve), p, broken).contains { $0.hasPrefix("\(big.name): ") && $0.contains("feed rate") })
        let inlay = InlayOperation(setup: OperationSetup(name: "I", toolID: vbit.id, shapeIDs: [id]),
                                   params: InlayParameters(flatClearanceToolID: big.id))
        #expect(warnings(.inlay(inlay), p, broken).contains { $0.hasPrefix("\(big.name): ") })
        let relief = Relief3DOperation(setup: OperationSetup(name: "R", toolID: finish.id),
                                       params: Relief3DParameters(modelID: UUID(), roughing: RoughingSettings(toolID: big.id)))
        #expect(warnings(.relief3D(relief), p, broken).contains { $0.hasPrefix("\(big.name): ") })
        #expect(OperationWarnings.secondaryToolIDs(of: pocket, primary: finish, library: broken, material: nil, units: .inch) == [big.id])
    }

    @Test func aPocketJudgesOnlyTheClearanceToolsTheGeneratorWillUse() throws {
        let (p, _, lib) = try setup()
        let id = p.document.shapes[0].id
        let quarter = try #require(lib.tools.first { $0.kind == .endMill && abs($0.diameter - 0.25) < 1e-9 })
        var half = try #require(lib.tools.first { $0.kind == .endMill && abs($0.diameter - 0.5) < 1e-9 })
        var eighth = try #require(lib.tools.first { $0.kind == .endMill && abs($0.diameter - 0.125) < 1e-9 })
        half.feedRate = 0; eighth.feedRate = 0
        var broken = lib
        broken.upsert(half); broken.upsert(eighth)
        var op = PocketOperation(setup: OperationSetup(name: "P", toolID: quarter.id, shapeIDs: [id]), params: PocketParameters())
        // Smaller than the finish tool: skipped by the generator, so not judged. Larger: judged.
        op.params.clearanceToolIDs = [eighth.id]
        #expect(warnings(.pocket(op), p, broken).isEmpty)
        op.params.clearanceToolIDs = [half.id]
        #expect(warnings(.pocket(op), p, broken).contains { $0.hasPrefix("\(half.name): ") })
        // Each must be smaller than the one before: a second 1/2 in tool is skipped.
        var half2 = half
        half2.id = UUID(); half2.name = "Another half"
        broken.upsert(half2)
        op.params.clearanceToolIDs = [half.id, half2.id]
        let w = warnings(.pocket(op), p, broken)
        #expect(w.allSatisfy { $0.hasPrefix("\(half.name): ") } && !w.isEmpty)
    }

    @Test func onlyToolsThatMakeACutAreJudged() throws {
        let (p, _, lib) = try setup()
        var broken = lib
        let finish = try #require(lib.tools.first { $0.kind == .endMill })
        var other = try #require(lib.tools.first { $0.kind == .endMill && $0.id != finish.id })
        other.feedRate = 0
        broken.upsert(other)
        let id = p.document.shapes[0].id
        // A V-carve's clearance tool only cuts with a flat depth.
        let vbit = try #require(lib.tools.first { $0.kind == .vBit })
        var carve = VCarveOperation(setup: OperationSetup(name: "V", toolID: vbit.id, shapeIDs: [id]),
                                    params: VCarveParameters(flatDepth: 0.2, flatClearanceToolID: other.id))
        #expect(warnings(.vcarve(carve), p, broken).contains { $0.hasPrefix("\(other.name): ") })
        carve.params.flatDepth = nil
        #expect(warnings(.vcarve(carve), p, broken).isEmpty)
        // A relief: the rest tool only says what was finished before, the roughing tool cuts only when roughing is on,
        // and the primary tool cuts only when finishing is on or it also does the roughing.
        var bad = finish
        bad.feedRate = 0
        var reliefLib = lib
        reliefLib.upsert(bad)
        func relief(rough: Bool, roughTool: UUID?, finishing: Bool, rest: UUID?) -> AnyOperation {
            var params = Relief3DParameters(modelID: UUID(), roughing: RoughingSettings(isEnabled: rough, toolID: roughTool))
            params.finishing.isEnabled = finishing
            params.finishing.rest = rest.map { .unresolved(toolID: $0) }
            return .relief3D(Relief3DOperation(setup: OperationSetup(name: "R", toolID: finish.id), params: params))
        }
        // Finish tool broken: judged when finishing runs, or when it also roughs; not when only another tool roughs.
        #expect(!warnings(relief(rough: false, roughTool: nil, finishing: true, rest: nil), p, reliefLib).isEmpty)
        #expect(!warnings(relief(rough: true, roughTool: nil, finishing: false, rest: nil), p, reliefLib).isEmpty)
        #expect(warnings(relief(rough: true, roughTool: other.id, finishing: false, rest: nil), p, reliefLib).isEmpty)
        // Roughing explicitly with the primary tool is the primary tool cutting.
        #expect(!warnings(relief(rough: true, roughTool: finish.id, finishing: false, rest: nil), p, reliefLib).isEmpty)
        #expect(warnings(relief(rough: false, roughTool: nil, finishing: false, rest: nil), p, reliefLib).isEmpty)
        // The rest tool is never judged; the roughing tool when roughing is on.
        #expect(warnings(relief(rough: false, roughTool: nil, finishing: true, rest: other.id), p, broken).isEmpty)
        #expect(warnings(relief(rough: true, roughTool: other.id, finishing: true, rest: nil), p, broken).contains { $0.hasPrefix("\(other.name): ") })
        #expect(warnings(relief(rough: false, roughTool: other.id, finishing: true, rest: nil), p, broken).isEmpty)
        // A merge has no tool of its own to judge, whatever its wrapper holds.
        var merged = MergeOperation(setup: OperationSetup(name: "M", toolID: other.id, shapeIDs: [id]), params: MergeParameters(children: []))
        merged.setup.toolID = other.id
        #expect(warnings(.merge(merged), p, broken).isEmpty)
    }

    @Test func theToolDatabaseJudgesSpindleSpeedByThePostAJobWouldStartWith() {
        let machines = BuiltInMachines.all, posts = BuiltInPosts.all
        // Out of the box: the Avid and its post.
        let avid = ToolDatabaseView.defaultPost(prefs: AppPreferences(), machines: machines, profiles: posts)
        #expect(avid.id == BuiltInPosts.avidMach4Inch.id && avid.minRPM == 6000 && avid.maxRPM == 24000)
        #expect(OperationWarnings.rpmProblem(1000, profile: avid) != nil)
        // The default machine decides the post when no post is chosen: GRBL runs lower speeds.
        var grbl = AppPreferences()
        grbl.defaultMachineID = BuiltInMachines.genericGRBL.id
        let g = ToolDatabaseView.defaultPost(prefs: grbl, machines: machines, profiles: posts)
        #expect(g.id == BuiltInPosts.genericGRBLMM.id)
        #expect(OperationWarnings.rpmProblem(1000, profile: g) == OperationWarnings.rpmProblem(1000, profile: BuiltInPosts.genericGRBLMM))
        // A machine's own spindle range replaces the post's.
        var spindle = BuiltInMachines.genericGRBL
        spindle.minRPM = 100; spindle.maxRPM = 500
        let own = ToolDatabaseView.defaultPost(prefs: grbl, machines: [spindle], profiles: posts)
        #expect(own.minRPM == 100 && own.maxRPM == 500)
        #expect(OperationWarnings.rpmProblem(300, profile: own) == nil && OperationWarnings.rpmProblem(1000, profile: own) != nil)
    }

    // MARK: Hole milling (issue #12)

    /// A job 0.75 in thick with circles at (3, 3) and (7, 3), and a 1/4 in end mill.
    func holes() throws -> (project: LoftLineProject, mill: Tool, library: ToolLibrary, centre: Shape, other: Shape) {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let library = AppTestSupport.library().library
        let mill = try #require(library.tools.first { $0.kind == .endMill && abs($0.diameter - 0.25) < 1e-9 })
        let a = Shape(name: "hole A", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(3, 3), radius: 0.75)])
        let b = Shape(name: "hole B", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(7, 3), radius: 0.75)])
        p.document.add(a); p.document.add(b)
        return (p, mill, library, a, b)
    }

    func holeMill(_ mill: Tool, _ shape: Shape, mode: HoleMillMode = .helical, depth: Double = 0.75, diameter: Double? = nil) -> HoleMillOperation {
        HoleMillOperation(setup: OperationSetup(name: "H", toolID: mill.id, shapeIDs: [shape.id]),
                          params: HoleMillParameters(mode: mode, cutDepth: depth, holeDiameter: diameter, threadPitch: 0.1))
    }

    /// A drill of `diameter` in the library (the seeded 1/4 in drill, resized).
    func drillTool(_ lib: inout ToolLibrary, diameter: Double) throws -> Tool {
        var t = try #require(lib.tools.first { $0.kind == .drill })
        t.id = UUID(); t.name = "Drill \(diameter)"; t.diameter = diameter
        lib.upsert(t)
        return t
    }

    func drill(_ tool: Tool, _ shape: Shape, depth: Double = 0.75, enabled: Bool = true) -> AnyOperation {
        .drill(DrillOperation(setup: OperationSetup(name: "D", isEnabled: enabled, toolID: tool.id, shapeIDs: [shape.id]),
                              params: DrillParameters(cutDepth: depth)))
    }

    @Test func aThroughHoleBoredWithAHelixWarnsAboutTheFreeSlug() throws {
        var (p, mill, lib, a, b) = try holes()
        let slugWide = try drillTool(&lib, diameter: 1.0), narrow = try drillTool(&lib, diameter: 0.25)
        // 1.5 in hole, 1/4 in tool: the ring leaves a 1 in core, and the cut reaches the 0.75 in bottom.
        let bore = holeMill(mill, a)
        p.operations = [.holeMill(bore)]
        let w = warnings(.holeMill(bore), p, lib)
        #expect(w.count == 1 && w[0].contains("1 through hole(s)") && w[0].contains("free slug up to 1 in wide") && w[0].contains("Drill the center out"))
        // Stopped short of the bottom, or a core no wider than the tool: nothing to jam.
        #expect(warnings(.holeMill(holeMill(mill, a, depth: 0.5)), p, lib).isEmpty)
        #expect(warnings(.holeMill(holeMill(mill, a, diameter: 0.7)), p, lib).isEmpty)           // core 0.2 in
        #expect(!warnings(.holeMill(holeMill(mill, a, diameter: 0.8)), p, lib).isEmpty)          // core 0.3 in
        // A copy of the array is a through hole too.
        var copiedBore = bore
        copiedBore.setup.arrayCopy = ArrayCopySettings(columns: 2, rows: 1, spacingX: 4, spacingY: 0)
        p.operations = [drill(slugWide, a), .holeMill(copiedBore)]
        #expect(warnings(.holeMill(copiedBore), p, lib).first?.contains("1 through hole(s)") == true)      // the copy at x = 7
        p.operations = [.holeMill(bore)]
        // Two holes are counted, the widest named.
        var two = bore
        two.setup.shapeIDs = [a.id, b.id]
        #expect(warnings(.holeMill(two), p, lib).first?.contains("2 through hole(s)") == true)
        // The drill-out is an earlier Drill at the center that goes through the material and is as wide as the slug.
        p.operations = [drill(slugWide, a), .holeMill(bore)]
        #expect(warnings(.holeMill(bore), p, lib).isEmpty)
        // Not one that is too narrow, too shallow, elsewhere, disabled or later in the list.
        for notEnough in [drill(narrow, a), drill(slugWide, a, depth: 0.5), drill(slugWide, b), drill(slugWide, a, enabled: false)] {
            p.operations = [notEnough, .holeMill(bore)]
            #expect(warnings(.holeMill(bore), p, lib).count == 1, "\(notEnough)")
        }
        p.operations = [.holeMill(bore), drill(slugWide, a)]
        #expect(warnings(.holeMill(bore), p, lib).count == 1)
        // A toolpath that is not in the list has nothing before it.
        p.operations = [drill(slugWide, a)]
        #expect(warnings(.holeMill(bore), p, lib).count == 1)
        // Holes smaller than the tool are skipped by the generator and not counted.
        two.params.holeDiameter = 0.2
        p.operations = [.holeMill(two)]
        #expect(warnings(.holeMill(two), p, lib).isEmpty)
    }

    @Test func aThreadWithNoPilotHoleBeforeItIsReported() throws {
        var (p, mill, lib, a, b) = try holes()
        let narrow = try drillTool(&lib, diameter: 0.125), wide = try drillTool(&lib, diameter: 0.5)
        let thread = holeMill(mill, a, mode: .thread, depth: 0.5, diameter: 1.0)
        p.operations = [.holeMill(thread)]
        let w = warnings(.holeMill(thread), p, lib)
        #expect(w.count == 1 && w[0].contains("1 hole(s) in thread mode have no pilot hole"))
        // Any earlier toolpath that clears the middle to the thread's depth, as wide as the thread mill, is a pilot: a
        // drill, a bore that leaves no core (a hole up to twice its tool), a pocket over it.
        let bore = AnyOperation.holeMill(holeMill(mill, a, depth: 0.5, diameter: 0.45))
        var pocketParams = PocketParameters()
        pocketParams.depth.cutDepth = 0.75
        let pocket = AnyOperation.pocket(PocketOperation(setup: OperationSetup(name: "P", toolID: mill.id, shapeIDs: [a.id]), params: pocketParams))
        let inside = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "I", toolID: mill.id, shapeIDs: [a.id]),
                                                           params: ProfileParameters(side: .inside)))
        for pilot in [drill(wide, a), bore, pocket] {
            p.operations = [pilot, .holeMill(thread)]
            #expect(warnings(.holeMill(thread), p, lib).isEmpty, "\(pilot.kind)")
        }
        // But not one that is too shallow or too narrow for the thread mill, later in the list, disabled, elsewhere, a
        // thread itself or an outside profile.
        var shallowPocket = pocketParams
        shallowPocket.depth.cutDepth = 0.3
        let outside = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "O", toolID: mill.id, shapeIDs: [a.id]), params: ProfileParameters(side: .outside)))
        let anotherThread = AnyOperation.holeMill(holeMill(mill, a, mode: .thread, depth: 0.5, diameter: 1.0))
        let notPilots: [AnyOperation] = [
            drill(narrow, a), drill(wide, a, depth: 0.3), drill(wide, b), drill(wide, a, enabled: false), outside, inside, anotherThread,
            .holeMill(holeMill(mill, a, depth: 0.5, diameter: 0.9)),                    // a ring: the middle stays solid
            .pocket(PocketOperation(setup: OperationSetup(name: "P", toolID: mill.id, shapeIDs: [a.id]), params: shallowPocket)),
            .holeMill(holeMill(mill, a, depth: 0.3, diameter: 0.9)),
        ]
        for notPilot in notPilots {
            p.operations = [notPilot, .holeMill(thread)]
            #expect(warnings(.holeMill(thread), p, lib).count == 1, "\(notPilot.kind)")
        }
        p.operations = [.holeMill(thread), drill(wide, a)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        // The pilot has to start at the top: a drill that starts 0.2 in down leaves that much for the thread mill to cut.
        var startsLow = DrillOperation(setup: OperationSetup(name: "D", toolID: wide.id, shapeIDs: [a.id]), params: DrillParameters(startDepth: 0.2, cutDepth: 0.75))
        p.operations = [.drill(startsLow), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        startsLow.params.startDepth = 0
        p.operations = [.drill(startsLow), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).isEmpty)
        // A pocket whose tool cannot reach the middle makes no pilot: a 1/2 in tool with a 0.1 in allowance does not enter a 0.4 in circle.
        let small = Shape(name: "small", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(3, 8), radius: 0.2)])
        p.document.add(small)
        var smallParams = PocketParameters(allowance: 0.1)
        smallParams.depth.cutDepth = 0.75
        let big = try #require(lib.tools.first { $0.kind == .endMill && abs($0.diameter - 0.5) < 1e-9 })
        let smallPocket = AnyOperation.pocket(PocketOperation(setup: OperationSetup(name: "SP", toolID: big.id, shapeIDs: [small.id]), params: smallParams))
        let smallThread = holeMill(mill, small, mode: .thread, depth: 0.5, diameter: 0.4)
        p.operations = [smallPocket, .holeMill(smallThread)]
        #expect(warnings(.holeMill(smallThread), p, lib).count == 1)
        smallParams.allowance = 0
        p.operations = [.pocket(PocketOperation(setup: OperationSetup(name: "SP", toolID: mill.id, shapeIDs: [small.id]), params: smallParams)), .holeMill(smallThread)]
        #expect(warnings(.holeMill(smallThread), p, lib).isEmpty)          // a 1/4 in tool reaches the middle of a 0.4 in circle
        // The copies of an array are holes too: a pilot at the original is no pilot at the copy.
        var copied = thread
        copied.setup.arrayCopy = ArrayCopySettings(columns: 2, rows: 1, spacingX: 4, spacingY: 0)
        p.operations = [drill(wide, a), .holeMill(copied)]
        #expect(warnings(.holeMill(copied), p, lib).count == 1)
        // ...unless the pilot is copied the same way.
        var copiedPilot = drill(wide, a)
        if case .drill(var d) = copiedPilot { d.setup.arrayCopy = ArrayCopySettings(columns: 2, rows: 1, spacingX: 4, spacingY: 0); copiedPilot = .drill(d) }
        p.operations = [copiedPilot, .holeMill(copied)]
        #expect(warnings(.holeMill(copied), p, lib).isEmpty)
        // A copy of the pocket that reaches the point counts by its own width, not the first that reaches it.
        var wideLeft = PocketParameters()
        wideLeft.depth.cutDepth = 0.75
        wideLeft.allowance = 0.05
        let big2 = try #require(lib.tools.first { $0.kind == .endMill && abs($0.diameter - 0.25) < 1e-9 })
        let narrowSpot = Shape(name: "narrow", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(7, 9), radius: 0.2)])
        let wideSpot = Shape(name: "wide", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(3, 9), radius: 0.75)])
        p.document.add(narrowSpot); p.document.add(wideSpot)
        var overlapping = PocketOperation(setup: OperationSetup(name: "SP2", toolID: big2.id, shapeIDs: [narrowSpot.id, wideSpot.id]), params: wideLeft)
        overlapping.setup.arrayCopy = ArrayCopySettings(columns: 2, rows: 1, spacingX: 4, spacingY: 0)
        let threadAtSeven = holeMill(mill, narrowSpot, mode: .thread, depth: 0.5, diameter: 0.4)
        p.operations = [.pocket(overlapping), .holeMill(threadAtSeven)]
        // At (7, 9) the narrow original reaches the point with too little room, and the copy of the wide circle with plenty.
        #expect(warnings(.holeMill(threadAtSeven), p, lib).isEmpty)
        // Another side or sheet is another program: its pilot is not this one's.
        var other = p
        other.document.job.twoSided = TwoSidedSetup()
        var pilot = DrillOperation(setup: OperationSetup(name: "D", toolID: wide.id, shapeIDs: [a.id]), params: DrillParameters(cutDepth: 0.75))
        other.document.layers = other.document.layers.map { var l = $0; l.side = .top; return l }
        other.operations = [.drill(pilot), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), other, lib).isEmpty)                     // same side: still a pilot
        if let layer = other.document.shapes(ids: [a.id]).first?.layerID, let i = other.document.layers.firstIndex(where: { $0.id == layer }) {
            var drillLayer = Layer(id: UUID(), name: "Bottom")
            drillLayer.side = .bottom
            other.document.layers.append(drillLayer)
            var moved = other.document.shape(id: a.id)!
            moved.id = UUID(); moved.layerID = drillLayer.id
            other.document.add(moved)
            pilot.setup.shapeIDs = [moved.id]
            other.operations = [.drill(pilot), .holeMill(thread)]
            #expect(warnings(.holeMill(thread), other, lib).count == 1, "a bottom-side drill is not this side's pilot \(i)")
        }
        // A toolpath whose vectors are on both sides has no side, and nothing is its pilot.
        var both = other
        pilot.setup.shapeIDs = [a.id]
        var spanning = thread
        spanning.setup.shapeIDs = [a.id, both.document.shapes.last!.id]      // the top-side vector and the bottom-side copy
        both.operations = [.drill(pilot), .holeMill(spanning)]
        #expect(warnings(.holeMill(spanning), both, lib).count == 1)
        // A pilot whose own depth is not deeper than its start depth cuts nothing.
        let broken = DrillOperation(setup: OperationSetup(name: "D", toolID: wide.id, shapeIDs: [a.id]), params: DrillParameters(startDepth: 0.75, cutDepth: 0.75))
        p.operations = [.drill(broken), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        // The same for a pocket, and a bore: depth no deeper than the start depth removes nothing.
        var flatPocket = pocketParams
        flatPocket.depth.startDepth = 0.75
        flatPocket.depth.cutDepth = 0.75
        p.operations = [.pocket(PocketOperation(setup: OperationSetup(name: "P", toolID: mill.id, shapeIDs: [a.id]), params: flatPocket)), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        var flatBore = holeMill(mill, a, depth: 0.5, diameter: 0.45)
        flatBore.params.startDepth = 0.5
        p.operations = [.holeMill(flatBore), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        // The pilot is at least as wide as the thread mill, to the float: a drill a hair narrower is no pilot.
        let hair = try drillTool(&lib, diameter: 0.2499)
        p.operations = [drill(hair, a), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        let exact = try drillTool(&lib, diameter: 0.25)
        p.operations = [drill(exact, a), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).isEmpty)
        // A pilot that is the thread mill's width but 0.001 in off its center leaves a strip of solid material.
        let offset = Shape(name: "offset", layerID: p.document.defaultLayerID, paths: [ShapeFactory.circle(center: Vec2(3.001, 3), radius: 0.5)])
        p.document.add(offset)
        let offCentre = holeMill(mill, offset, mode: .thread, depth: 0.5, diameter: 1.0)
        p.operations = [drill(exact, a), .holeMill(offCentre)]
        #expect(warnings(.holeMill(offCentre), p, lib).count == 1)
        p.operations = [drill(wide, a), .holeMill(offCentre)]                       // a 1/2 in drill covers it with room to spare
        #expect(warnings(.holeMill(offCentre), p, lib).isEmpty)
        // A toolpath projected onto a 3D model is cut to depths only calculating knows: nothing is judged, and a projected
        // drill is no pilot.
        var projected = thread
        projected.setup.projectOntoModelID = UUID()
        p.operations = [.holeMill(projected)]
        #expect(warnings(.holeMill(projected), p, lib).count == 1 && warnings(.holeMill(projected), p, lib)[0].contains("cannot be judged"))
        // ...and a projected bore that could leave a slug says so too, while a small one, where neither can arise, says nothing.
        var projectedBore = holeMill(mill, a)
        projectedBore.setup.projectOntoModelID = UUID()
        #expect(warnings(.holeMill(projectedBore), p, lib).first?.contains("cannot be judged") == true)
        projectedBore.params.holeDiameter = 0.4
        #expect(warnings(.holeMill(projectedBore), p, lib).isEmpty)
        // A projected thread in a hole as large as the tool is skipped by the generator and has no pilot to judge.
        projected.params.holeDiameter = 0.25
        #expect(warnings(.holeMill(projected), p, lib).isEmpty)
        var projectedDrill = DrillOperation(setup: OperationSetup(name: "D", toolID: wide.id, shapeIDs: [a.id]), params: DrillParameters(cutDepth: 0.75))
        projectedDrill.setup.projectOntoModelID = UUID()
        p.operations = [.drill(projectedDrill), .holeMill(thread)]
        #expect(warnings(.holeMill(thread), p, lib).count == 1)
        // The boundary is the generator's: a thread diameter 0.0012 in over the tool has a 0.0006 in radius, above the 0.0005 in
        // tolerance, so the generator mills it, plunging at the center, and it needs its pilot.
        let barely = holeMill(mill, a, mode: .thread, depth: 0.5, diameter: 0.2512)
        p.operations = [.holeMill(barely)]
        #expect(warnings(.holeMill(barely), p, lib).count == 1)
        // A thread in a hole as large as the tool is skipped by the generator, and not reported here.
        let tiny = holeMill(mill, a, mode: .thread, depth: 0.5, diameter: 0.25)
        p.operations = [.holeMill(tiny)]
        #expect(warnings(.holeMill(tiny), p, lib).isEmpty)
    }
}
