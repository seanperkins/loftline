import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

private let tool = PostFixtures.endMill

private func job(_ tps: [Toolpath], units: LengthUnit = .inch) -> PostJob {
    PostJob(name: "T", units: units, job: PostFixtures.job(), toolpaths: tps)
}

private func lines(_ program: String) -> [String] { program.split(separator: "\n").map(String.init) }

/// Lines after the last header/tool-change comment for the first toolpath.
private func body(_ program: String) -> [String] {
    let l = lines(program)
    guard let i = l.firstIndex(where: { $0.hasPrefix("( Toolpath:") }) else { return [] }
    return Array(l[(i + 1)...])
}

@Test func postRequiresToolpaths() {
    #expect(throws: PostError.noToolpaths) {
        try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([]))
    }
    let empty = Toolpath(name: "e", kind: .profile, tool: tool)
    #expect(throws: PostError.noToolpaths) {
        try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([empty]))
    }
}

@Test func postRejectsSpindleSpeedOutsideMachineRange() {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, spindleRPM: 30000,
                      moves: [.rapid(to: Vec3(0, 0, 0.2))])
    #expect(throws: PostError.spindleSpeedOutOfRange(30000)) {
        try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([tp]))
    }
}

@Test func xyRapidBelowSafeZIsPrecededByRetract() throws {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(0, 0, 0.2)),
        .linear(to: Vec3(0, 0, -0.1), feed: 30),
        .rapid(to: Vec3(2, 0, -0.05)),   // bad generator output: XY rapid low
    ])
    let b = body(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([tp])))
    #expect(Array(b.prefix(5)) == ["G0 X0.0000 Y0.0000", "G1 Z-0.1000 F30.0", "G0 Z0.2000",
                                   "X2.0000", "Z-0.0500"])
}

@Test func feedIsModalUnlessProfileDisablesIt() throws {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(0, 0, 0.2)),
        .linear(to: Vec3(0, 0, -0.1), feed: 30),
        .linear(to: Vec3(1, 0, -0.1), feed: 100),
        .linear(to: Vec3(1, 1, -0.1), feed: 100),
        .rapid(to: Vec3(1, 1, 0.2)),
    ])
    let modal = body(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([tp])))
    #expect(Array(modal.prefix(4)) == ["G0 X0.0000 Y0.0000", "G1 Z-0.1000 F30.0", "X1.0000 F100.0", "Y1.0000"])

    var p = BuiltInPosts.avidMach4Inch
    p.modal = false
    let full = body(try TemplatePostProcessor(profile: p).post(job([tp])))
    #expect(full[3] == "G1 X1.0000 Y1.0000 Z-0.1000 F100.0")
}

@Test func arcsAsIncrementalAbsoluteOrLinearized() throws {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(2, 1, 0.2)),
        .linear(to: Vec3(2, 1, -0.1), feed: 30),
        .arcCW(to: Vec3(0, 1, -0.1), center: Vec2(1, 1), feed: 100),
        .rapid(to: Vec3(0, 1, 0.2)),
    ])
    var p = BuiltInPosts.avidMach4Inch
    #expect(body(try TemplatePostProcessor(profile: p).post(job([tp])))[2]
            == "G2 X0.0000 Y1.0000 I-1.0000 J0.0000 F100.0")
    p.arcOutput = .absoluteIJ
    #expect(body(try TemplatePostProcessor(profile: p).post(job([tp])))[2]
            == "G2 X0.0000 Y1.0000 I1.0000 J1.0000 F100.0")
    p.arcOutput = .linearize
    let lin = try TemplatePostProcessor(profile: p).post(job([tp]))
    #expect(!lines(lin).contains { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") })
    let pts = body(lin).dropFirst(2).prefix { !$0.hasPrefix("G0") }
    #expect(pts.count > 20)
    #expect(pts.last?.contains("X0.0000 Y1.0000") == true)
    // Every linearised point lies on the unit circle around (1,1) and below the start (CW from +X).
    #expect(lin.components(separatedBy: "\n").contains { $0.contains("Y0.0") })
}

@Test func helicalArcsAreLinearizedWhenUnsupported() throws {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(2, 1, 0.2)),
        .linear(to: Vec3(2, 1, 0), feed: 30),
        .arcCCW(to: Vec3(2, 1, -0.1), center: Vec2(1, 1), feed: 100),   // full-circle helix
        .rapid(to: Vec3(2, 1, 0.2)),
    ])
    var p = BuiltInPosts.avidMach4Inch
    #expect(body(try TemplatePostProcessor(profile: p).post(job([tp])))[2]
            == "G3 X2.0000 Y1.0000 Z-0.1000 I-1.0000 J0.0000 F100.0")
    p.helicalArcs = false
    let out = try TemplatePostProcessor(profile: p).post(job([tp]))
    #expect(!lines(out).contains { $0.hasPrefix("G3 ") })
}

@Test func lineNumbersSkipComments() throws {
    var p = BuiltInPosts.avidMach4Inch
    p.lineNumbers = true
    let l = lines(try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()))
    #expect(l.first?.hasPrefix("(") == true)
    let numbered = l.filter { $0.hasPrefix("N") }
    #expect(numbered.first == "N10 G20")
    #expect(numbered.count == l.filter { !$0.hasPrefix("(") }.count)
    #expect(l.contains("(Change to Tool: 1/4\" End Mill [2 flute])"))
}

@Test func toolLengthOffsetIsOptional() throws {
    var p = BuiltInPosts.avidMach4Inch
    #expect(!(try TemplatePostProcessor(profile: p).post(PostFixtures.postJob())).contains("G43"))
    p.useToolLengthOffset = true
    let l = lines(try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()))
    let i = try #require(l.firstIndex(of: "T1 M6"))
    #expect(l[i + 1] == "G43 H1")
    #expect(l.contains("G43 H6"))
}

@Test func combinedExportGroupsByToolWithOneChangeEach() throws {
    let tps = PostFixtures.toolpaths()
    let a2 = Toolpath(name: "Pocket 1", kind: .pocket, tool: PostFixtures.endMill, moves: tps[0].moves)
    let out = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch)
        .postCombined(job([tps[0], tps[1], a2]))
    let l = lines(out)
    #expect(l.filter { $0 == "T1 M6" }.count == 1)
    #expect(l.filter { $0 == "T6 M6" }.count == 1)
    let names = l.filter { $0.hasPrefix("( Toolpath:") }
    #expect(names == ["( Toolpath: Profile 1 [Profile] )", "( Toolpath: Pocket 1 [Pocket] )",
                      "( Toolpath: V-Carve 1 [V-Carve] )"])
    // Spindle stops before every tool change.
    for (i, line) in l.enumerated() where line.hasSuffix(" M6") { #expect(l[i - 2] == "M5") }
}

@Test func rpmChangeWithinToolRestartsSpindle() throws {
    let tps = PostFixtures.toolpaths()
    let slower = Toolpath(name: "Slow", kind: .profile, tool: PostFixtures.endMill, spindleRPM: 12000,
                          moves: tps[0].moves)
    let l = lines(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([tps[0], slower])))
    #expect(l.filter { $0.hasPrefix("M3 ") } == ["M3 S18000", "M3 S12000"])
    #expect(l.filter { $0 == "G4 P3" }.count == 2)
}

@Test func dwellMovesAndSpindleDwellUseTemplate() throws {
    var p = BuiltInPosts.avidMach4Inch
    p.spindleDwellSeconds = 0
    let tp = Toolpath(name: "d", kind: .drill, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.2), feed: 20), .dwell(seconds: 0.5),
        .rapid(to: Vec3(1, 1, 0.2)),
    ])
    let l = lines(try TemplatePostProcessor(profile: p).post(job([tp])))
    #expect(l.filter { $0.hasPrefix("G4 ") } == ["G4 P0.5"])
}

/// A controller whose `G4 P` is milliseconds (MASSO, NcStudio, UCCNC by default; #99 item 1) gets `{MILLISECONDS}`.
@Test func dwellInMilliseconds() throws {
    var p = BuiltInPosts.avidMach4Inch
    p.id = "ms"
    p.dwell = "G4 P{MILLISECONDS}"
    let tp = Toolpath(name: "d", kind: .drill, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.2), feed: 20), .dwell(seconds: 0.5),
        .rapid(to: Vec3(1, 1, 0.2)),
    ])
    let l = lines(try TemplatePostProcessor(profile: p).post(job([tp])))
    let start = try #require(l.firstIndex { $0.hasPrefix("M3 ") })
    #expect(l[start + 1] == "G4 P3000")
    #expect(l.filter { $0.hasPrefix("G4 ") } == ["G4 P3000", "G4 P500"])
    #expect(p.dwellValues(seconds: 0.125)["MILLISECONDS"] == "125")
    #expect(p.dwellValues(seconds: 2.9996)["MILLISECONDS"] == "3000")
    #expect(p.dwellValues(seconds: 0.0004)["MILLISECONDS"] == "0")
    #expect(p.dwellValues(seconds: 3600)["MILLISECONDS"] == "3600000")
    #expect(p.dwellValues(seconds: 3)["SECONDS"] == "3")
}

/// No dwell over an hour: `{MILLISECONDS}` of an absurd value would print `INF` (#99 review).
@Test func dwellBounds() throws {
    var p = BuiltInPosts.avidMach4Inch
    p.spindleDwellSeconds = 3601
    #expect(throws: SnapshotError.self) { try PostProfile.fromJSON(p.toJSON()) }
    p.spindleDwellSeconds = 3600
    #expect(throws: Never.self) { try PostProfile.fromJSON(p.toJSON()) }
    let tp = Toolpath(name: "Long", kind: .drill, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.2), feed: 20), .dwell(seconds: 3601),
        .rapid(to: Vec3(1, 1, 0.2)),
    ])
    #expect(throws: PostError.dwellTooLong(toolpath: "Long", seconds: 3601)) {
        try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job([tp]))
    }
}

/// The dwell rules hold when posting, not only in the editor: a post file or a project copy never passes the editor.
@Test func dwellRulesAreEnforcedWhenPosting() throws {
    var grbl = BuiltInPosts.avidMach4Inch
    grbl.id = "shop-grbl"
    grbl.controller = .grbl
    grbl.dwell = "G4 P{MILLISECONDS}"
    var othermill = BuiltInPosts.othermillInch
    othermill.dwell = "G4 P{MILLISECONDS}"
    var mixed = BuiltInPosts.avidMach4Inch
    mixed.id = "mixed"
    mixed.dwell = "G4 P{MILLISECONDS}"
    mixed.pause = ["M5", "G4 P{SECONDS}", "M0"]
    for p in [grbl, othermill, mixed] {
        let problem = try #require(p.dwellProblem, "\(p.id)")
        #expect(throws: PostError.invalidPost(problem)) {
            try TemplatePostProcessor(profile: p).post(job(PostFixtures.toolpaths()))
        }
    }
    var fine = mixed
    fine.pause = nil
    #expect(fine.dwellProblem == nil)
    #expect(BuiltInPosts.all.allSatisfy { $0.dwellProblem == nil })
}

/// Every built-in controller that reads `G4 P` in seconds refuses a millisecond dwell, edited copies keeping the id included.
@Test func secondsControllersRefuseMillisecondDwells() {
    for builtIn in [BuiltInPosts.onefinityBBInch, BuiltInPosts.carbideMotionMM, BuiltInPosts.genericGRBLMM,
                    BuiltInPosts.genericGRBLInch] {
        var p = builtIn
        p.dwell = "G4 P{MILLISECONDS}"
        #expect(p.dwellProblem != nil, "\(p.id)")
    }
}

/// A built-in family's dwell unit is its own template's, both ways, duplicates included (#107, #108, #103).
@Test func aBuiltInFamilysDwellUnitIsKept() {
    func with(_ p: PostProfile, _ dwell: String, id: String? = nil) -> PostProfile {
        var q = p; q.dwell = dwell; if let id { q.id = id }; return q
    }
    let refused = [with(BuiltInPosts.massoG3MM, "G4 P{SECONDS}"), with(BuiltInPosts.uccncInch, "G4 P{SECONDS}"),
                   with(BuiltInPosts.massoG3MM, "G4 P{SECONDS}", id: "masso-g3-mm-custom-1"),
                   with(BuiltInPosts.centroidInch, "G4 P{MILLISECONDS}"), with(BuiltInPosts.avidMach4Inch, "G4 P{MILLISECONDS}"),
                   with(BuiltInPosts.genericGRBLMM, "G4 P{MILLISECONDS}", id: "generic-grbl-mm-custom-2")]
    for p in refused { #expect(p.dwellProblem != nil, "\(p.id) \(p.dwell)") }
    #expect(with(BuiltInPosts.massoG3MM, "G4 P{SECONDS}").dwellProblem?.contains("milliseconds") == true)
    #expect(BuiltInPosts.all.allSatisfy { $0.dwellProblem == nil })
    #expect(with(BuiltInPosts.avidMach4Inch, "G4 P{MILLISECONDS}", id: "my-mach4-ms").dwellProblem == nil)
}

@Test func semicolonCommentsBracketParentheses() {
    var p = BuiltInPosts.genericGRBLMM
    p.commentStyle = .semicolon
    #expect(p.comment("a (b)") == "; a [b]")
}

@Test func millimetreDocumentPostedInInches() throws {
    let tp = Toolpath(name: "x", kind: .profile, tool: PostFixtures.endMill.converted(to: .millimeter), moves: [
        .rapid(to: Vec3(25.4, 50.8, 5.08)),
        .linear(to: Vec3(25.4, 50.8, -6.35), feed: 762),
        .rapid(to: Vec3(25.4, 50.8, 5.08)),
    ])
    let pj = PostJob(name: "mm", units: .millimeter, job: PostFixtures.job().scaled(by: 25.4), toolpaths: [tp])
    let out = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(pj)
    #expect(body(out).prefix(2) == ["G0 X1.0000 Y2.0000", "G1 Z-0.2500 F30.0"])
    #expect(out.contains("( Material: 12.0000 x 8.0000 x 0.7500 in )"))
}

@Test func headerDescribesJob() throws {
    let out = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(PostFixtures.postJob())
    for s in ["( Job: Golden )", "( Post: Avid PRO6096 Mach4 [inch] v1.0 )",
              "( Z zero: material top [bottom at Z-0.7500] )", "( XY origin: lower left )",
              "(   T6: 60 deg V-Bit 1/2\" - V-Bit, dia 0.5000 in )", "( Estimated time: "] {
        #expect(out.contains(s), "missing \(s)")
    }
    var p = BuiltInPosts.avidMach4Inch
    p.headerComments = false
    #expect(lines(try TemplatePostProcessor(profile: p).post(PostFixtures.postJob())).first == "G20")
}

@Test func customProfileFromJSONWithSemicolonComments() throws {
    var p = BuiltInPosts.genericGRBLMM
    p.id = "custom"; p.commentStyle = .semicolon; p.footer = ["M5", "M2"]
    let loaded = try PostProfile.fromJSON(p.toJSON())
    let out = try TemplatePostProcessor(profile: loaded).post(PostFixtures.postJob())
    #expect(out.hasPrefix("; Job: Golden\n"))
    #expect(out.hasSuffix("M5\nM2\n"))
    #expect(TemplatePostProcessor(profile: loaded).fileName(for: "Sign") == "Sign.nc")
    #expect(TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).fileName(for: "") == "Untitled.tap")
}

@Test func timeEstimateCountsFeedsRapidsAndDwells() {
    let tp = Toolpath(name: "x", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(0, 0, 0)),
        .linear(to: Vec3(10, 0, 0), feed: 60),     // 10 s
        .rapid(to: Vec3(10, 60, 0)),               // 60 in at 600 ipm = 6 s
        .dwell(seconds: 2),
    ])
    let t = PostTimeEstimator.estimate([tp], rapidRate: 600, spindleDwell: 3)
    #expect(abs(t - 21) < 1e-9)
}

@Test func numberFormatting() {
    #expect(NumberFormat.fixed(-0.00001, decimals: 4) == "0.0000")
    #expect(NumberFormat.fixed(1.23456, decimals: 3) == "1.235")
    #expect(NumberFormat.compact(3) == "3" && NumberFormat.compact(0.25) == "0.25")
    #expect(NumberFormat.duration(3725) == "1h 02m 05s")
    #expect(PostProfile.asciiOnly("90° café") == "90 deg cafe")
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func footerParksAtHomeZBeforeHomeXY(mode: ZZeroMode) throws {
    let pj = PostFixtures.postJob(zZero: mode)
    let out = lines(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(pj))
    let end = try #require(out.lastIndex(of: "M30"))
    let zi = try #require(out[..<end].lastIndex { $0.hasPrefix("G0 Z") })
    let lastZ = out[zi]
    let homeZ = MachineCoordinates(job: pj.job).homeZ
    #expect(lastZ == "G0 Z" + NumberFormat.fixed(homeZ, decimals: 4))
    #expect(abs(homeZ - MachineCoordinates(job: pj.job).safeZ) > 1e-6, "fixture must tell Home Z and Safe Z apart")
    let xy = try #require(out.lastIndex(of: "G0 X0.0000 Y0.0000"))
    #expect(zi < xy)
}

@Test func programsStateTheArcCentreMode() throws {
    let out = lines(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(PostFixtures.postJob()))
    #expect(out.contains("G91.1") && !out.contains("G90.1"))
    var absolute = BuiltInPosts.avidMach4Inch
    absolute.arcOutput = .absoluteIJ
    absolute.preamble = ["G90", "G17"]
    let absOut = lines(try TemplatePostProcessor(profile: absolute).post(PostFixtures.postJob()))
    #expect(absOut.contains("G90.1"))
}
