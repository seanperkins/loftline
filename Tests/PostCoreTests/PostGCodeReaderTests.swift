import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// Cutting/arc targets in order (rapids and dwells ignored), rounded to 4 decimals.
private func cutTargets(_ moves: [Move]) -> [String] {
    moves.compactMap { m -> String? in
        guard !m.isRapid, let t = m.target else { return nil }
        let arc: String
        switch m {
        case .arcCW(_, let c, _): arc = String(format: " cw %.4f %.4f", c.x, c.y)
        case .arcCCW(_, let c, _): arc = String(format: " ccw %.4f %.4f", c.x, c.y)
        default: arc = ""
        }
        return String(format: "%.4f %.4f %.4f", t.x, t.y, t.z) + arc
    }
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func postReaderReadsBackOurOwnProgram(mode: ZZeroMode) throws {
    let job = PostFixtures.postJob(zZero: mode)
    let text = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job)
    let coords = MachineCoordinates(job: job.job)
    let r = GCodeReader.read(text, units: .inch, startZ: coords.safeZ)
    #expect(r.programUnits == .inch)
    #expect(r.segments.map(\.toolNumber) == [1, 6])
    #expect(r.segments.map(\.spindleRPM) == job.toolpaths.map(\.spindleRPM))
    for (seg, tp) in zip(r.segments, job.toolpaths) {
        #expect(cutTargets(seg.moves) == cutTargets(tp.moves))
    }
    let tools = GCodeReader.headerTools(text, units: .inch)
    #expect(tools[1]?.kind == .endMill && abs((tools[1]?.diameter ?? 0) - 0.25) < 1e-9)
    #expect(tools[6]?.kind == .vBit)
    // Read in millimetres: everything scales.
    let mm = GCodeReader.read(text, units: .millimeter, startZ: 5)
    let a = try #require(r.segments[0].moves.last { !$0.isRapid }?.target)
    let b = try #require(mm.segments[0].moves.last { !$0.isRapid }?.target)
    #expect(abs(b.x - a.x * 25.4) < 1e-6 && abs(b.z - a.z * 25.4) < 1e-6)
}

@Test func postReaderHandlesRArcsIncrementalAndCycles() throws {
    let text = """
    G21 G90 G17
    T2 M6 (6mm end mill)
    S12000 M3
    G0 X0 Y0 Z5
    G1 Z-1 F300
    G2 X10 Y0 R5
    G3 X0 Y0 R-5
    G91 G1 X5 Y5
    G90
    G99 G81 X20 Y20 Z-3 R2 F100
    X30
    G80
    G0 Z5
    M30
    """
    let r = GCodeReader.read(text, units: .millimeter, startZ: 5)
    #expect(r.segments.count == 1)
    let s = r.segments[0]
    #expect(s.toolNumber == 2 && s.toolComment == "6mm end mill" && s.spindleRPM == 12000)
    let arcs = s.moves.filter(\.isArc)
    #expect(arcs.count == 2)
    if case .arcCW(_, let c, _) = arcs[0] { #expect(c.distance(to: Vec2(5, 0)) < 1e-9) } else { Issue.record("not cw") }
    // G91 move from (0,0) by (5,5).
    #expect(s.moves.contains { $0.target == Vec3(5, 5, -1) })
    // Two drilled holes to Z-3, each retracting to R2.
    let holes = s.moves.filter { if case .linear(let t, _) = $0 { return abs(t.z + 3) < 1e-9 } else { return false } }
    #expect(holes.map { $0.target!.xy } == [Vec2(20, 20), Vec2(30, 20)])
    #expect(r.warnings.isEmpty)
}

@Test func postReaderWarnsAboutWhatItCannotPreview() {
    let r = GCodeReader.read("G0 X1 Y1\nG28 X0 Y0\nX2\n", units: .inch, startZ: 0.2)
    #expect(r.programUnits == nil)
    #expect(r.warnings.contains { $0.contains("G20/G21") })
    #expect(r.warnings.contains { $0.contains("G28") })
    #expect(r.moveCount == 2)
}

/// The preview reads probed tool changes: the probe is not drawn, the zero sets Z, and a program with no M6 starts a
/// tool segment at each T word.
@Suite struct ProbedProgramReaderTests {
    func targets(_ r: GCodeReader.Result) -> [Vec3] { r.segments.flatMap(\.moves).compactMap(\.target) }

    @Test func grblZeroSetsZAndTheProbeIsNotDrawn() {
        let text = "G21\nG90\nG0 X0 Y0 Z50\nG91\nG38.2 Z-10 F100\nG90\nG10 L20 P1 Z12\nG91\nG0 Z5\nG90\n"
        let r = GCodeReader.read(text, units: .millimeter, startZ: 5)
        #expect(targets(r) == [Vec3(0, 0, 50), Vec3(0, 0, 17)])
        #expect(!r.warnings.contains { $0.contains("not previewed") })
    }

    @Test func mach4MacroSetsZ() {
        let text = "G20\nG90\nG0 X0 Y0 Z2\nG91\nG31 Z-0.5 F5\nG90\nM199 P0.5\nG17 G40 G49 G80 G90 G94 G91.1 G20 G54\nG91\nG0 Z0.2\nG90\n"
        let r = GCodeReader.read(text, units: .inch, startZ: 0.2)
        #expect(targets(r).last.map { abs($0.z - 0.7) < 1e-9 } == true)
    }

    @Test func probedTwoToolProgramsHaveTwoSegmentsAndNoPhantomPlunge() throws {
        let tps = [ProbeSequenceBuilderTests.cut("A"), ProbeSequenceBuilderTests.cut("B", tool: PostFixtures.vBit, at: 3)]
        let text = try TemplatePostProcessor(profile: ProbeSequenceBuilderTests.profile(BuiltInPosts.avidMach4Inch))
            .post(PostJob(name: "P", units: .inch, job: ProbeSequenceBuilderTests.job(), toolpaths: tps))
        let r = GCodeReader.read(text, units: .inch, startZ: 0.2)
        #expect(r.segments.map(\.toolNumber) == [1, 6])
        #expect(targets(r).allSatisfy { $0.z >= -0.1 - 1e-9 }, "a move below the deepest cut")
        #expect(!r.warnings.contains { $0.contains("not previewed") })
    }

    @Test func m6ProgramsKeepTodaysSegments() {
        // A post that pre-stages the next tool: T2 is named while T1 still cuts.
        let text = "G20\nG90\nT1 M6\nG0 X0 Y0 Z1\nT2\nG1 Z-0.1 F10\nT2 M6\nG1 X1 F10\n"
        let r = GCodeReader.read(text, units: .inch, startZ: 1)
        #expect(r.segments.map(\.toolNumber) == [1, 2])
        #expect(r.segments.map(\.moves.count) == [2, 1])
    }
}
