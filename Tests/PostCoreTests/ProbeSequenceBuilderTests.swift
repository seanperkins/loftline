import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The park, swap and touch-plate sequence the builder writes at every tool change (spec §4), and the conditions under
/// which no valid program can be written.
@Suite struct ProbeSequenceBuilderTests {
    static let mach4 = ToolChangeProbe(parkX: 2, parkY: -2, parkZ: -0.5, topZ: 0, plateThickness: 0.5, plateSize: 3,
                                       probeFeed: 5, probeTravel: 0.5, controller: .mach4, mach4ZeroMacro: 199)
    static let grbl = ToolChangeProbe(parkX: 10, parkY: 10, parkZ: -5, topZ: -1, plateThickness: 12, plateSize: 60,
                                      probeFeed: 100, probeTravel: 10, controller: .grbl)

    static func job(_ units: LengthUnit = .inch, zZero: ZZeroMode = .materialTop, spot: Vec2? = Vec2(6, 4)) -> JobSetup {
        var j = units == .inch ? PostFixtures.job(zZero: zZero)
            : JobSetup(width: 300, height: 200, thickness: 18, xyOrigin: .lowerLeft, zZero: zZero, safeZ: 5, homeZ: 20)
        j.touchOffSpot = spot
        return j
    }

    /// A short cut at depth 0.1 (inch) or 2.5 (mm) below the top, starting at `x`.
    static func cut(_ name: String, tool: Tool = PostFixtures.endMill, at x: Double = 1, job: JobSetup = job()) -> Toolpath {
        let mc = MachineCoordinates(job: job)
        let d = mc.z(depth: job.thickness > 5 ? 2.5 : 0.1)
        return Toolpath(name: name, kind: .profile, tool: tool, moves: [
            .rapid(to: Vec3(x, 1, mc.safeZ)), .linear(to: Vec3(x, 1, d), feed: 30),
            .linear(to: Vec3(x + 1, 1, d), feed: 100), .rapid(to: Vec3(x + 1, 1, mc.safeZ)),
        ])
    }

    static func profile(_ base: PostProfile, machine: MachineDefinition = BuiltInMachines.avidPRO6096,
                        probe: ToolChangeProbe? = mach4) -> PostProfile {
        var m = machine
        m.toolChangeProbe = probe
        return m.applied(to: base)
    }

    static func post(_ tps: [Toolpath], profile: PostProfile = profile(BuiltInPosts.avidMach4Inch), job: JobSetup = job(),
                     units: LengthUnit = .inch) throws -> [String] {
        let pj = PostJob(name: "P", units: units, job: job, toolpaths: tps)
        return try TemplatePostProcessor(profile: profile).post(pj).split(separator: "\n").map(String.init)
    }

    func refusal(_ tps: [Toolpath] = [cut("A")], profile: PostProfile = profile(BuiltInPosts.avidMach4Inch),
                 job: JobSetup = job(), units: LengthUnit = .inch) -> String? {
        do { _ = try Self.post(tps, profile: profile, job: job, units: units); return nil } catch PostError.probe(let m) {
            return m
        } catch { return "unexpected \(error)" }
    }

    static func msg(_ text: String) -> String { "(MSG, \(TemplateRenderer.commentSafe(text)))" }
    static let placement = "Clip the probe lead on the bit and touch the plate to it: the probe light must come on. "
        + "Place the plate under the bit. Jog Z only, down to about %@ above the plate"

    // MARK: Exact lines

    @Test func oneToolMach4Inch() throws {
        let lines = try Self.post([Self.cut("A")])
        let start = try #require(lines.firstIndex(of: "M5"))
        let name = PostFixtures.endMill.name
        #expect(Array(lines[start..<(start + 23)]) == [
            "M5", "G90 G92.1 G54",
            "G53 G0 Z0.0000", "G53 G0 X2.0000 Y-2.0000", "G53 G0 Z-0.5000",
            "T1", Self.msg("Load T1: \(name)"), "M0",
            "G53 G0 Z0.0000",
            "G0 X6.0000 Y4.0000",
            Self.msg(String(format: Self.placement, "0.25 in")), "M0",
            "G91", "G31 Z-0.5000 F5.0", "G90",
            "M199 P0.5000", "G17 G40 G49 G80 G90 G94 G91.1 G20 G54",
            "G0 Z0.7000",
            Self.msg("Remove the touch plate"), "M0",
            "G0 Z0.7000", "X1.0000 Y1.0000",
            "M3 S\(Int(PostFixtures.endMill.spindleRPM))",
        ])
        #expect(!lines.contains { $0.hasSuffix("M6") || $0.hasPrefix("G43") })
    }

    @Test func twoToolsGRBLmm() throws {
        let job = Self.job(.millimeter, spot: Vec2(150, 100))
        let profile = Self.profile(BuiltInPosts.genericGRBLMM, machine: BuiltInMachines.genericGRBL, probe: Self.grbl)
        let lines = try Self.post([Self.cut("A", at: 10, job: job), Self.cut("B", tool: PostFixtures.vBit, at: 40, job: job)],
                                  profile: profile, job: job, units: .millimeter)
        #expect(lines.filter { $0 == "G38.2 Z-10.000 F100" }.count == 2)
        #expect(lines.filter { $0 == "G10 L20 P1 Z12.000" }.count == 2)
        #expect(lines.filter { $0 == "G0 Z17.000" }.count >= 2)
        #expect(lines.filter { $0 == "G53 G0 Z-1.000" }.count == 4)
        #expect(!lines.contains { $0.hasPrefix("M199") || $0.hasPrefix("G17 G40") })
        // The second sequence retracts first, like any tool change.
        let second = try #require(lines.lastIndex(of: "G90 G92.1 G54"))
        #expect(lines[second - 1] == "M5")
    }

    @Test func mmDocumentInchPost() throws {
        let job = Self.job(.millimeter, spot: Vec2(152.4, 101.6))
        let lines = try Self.post([Self.cut("A", at: 25.4, job: job)], job: job, units: .millimeter)
        #expect(lines.contains("G0 X6.0000 Y4.0000"))
        #expect(lines.contains("M199 P0.5000"))
    }

    @Test func centreOriginWithDatumOffset() throws {
        var job = Self.job()
        job.xyOrigin = .center; job.datumOffset = Vec2(0.5, -0.25)
        let lines = try Self.post([Self.cut("A", job: job)], job: job)
        // Spot (6, 4) in the material frame; the origin is the centre (6, 4) plus (0.5, -0.25).
        #expect(lines.contains("G0 X-0.5000 Y0.2500"))
    }

    @Test func bothZZeroModes() throws {
        let top = try Self.post([Self.cut("A")])
        #expect(top.contains("M199 P0.5000") && top.contains("G0 Z0.7000"))
        let spoil = Self.job(zZero: .spoilboard)
        let lines = try Self.post([Self.cut("A", job: spoil)], job: spoil)
        #expect(lines.contains("M199 P1.2500") && lines.contains("G0 Z1.4500"))
    }

    @Test func plateThickerThanSafeZ() throws {
        var probe = Self.mach4
        probe.plateThickness = 1; probe.probeTravel = 0.5
        let lines = try Self.post([Self.cut("A")], profile: Self.profile(BuiltInPosts.avidMach4Inch, probe: probe))
        let zero = try #require(lines.firstIndex(of: "M199 P1.0000"))
        // From the zero until X/Y leaves the spot, nothing goes below clear Z (1.2).
        let cross = try #require(lines[zero...].firstIndex { $0.hasPrefix("X") || $0.contains(" X") })
        for l in lines[zero..<cross] where l.hasPrefix("G0 Z") { #expect(Double(l.dropFirst(4))! >= 1.2) }
    }

    @Test func feedFloored() throws {
        var probe = Self.mach4
        probe.probeFeed = 4.99
        #expect(try Self.post([Self.cut("A")], profile: Self.profile(BuiltInPosts.avidMach4Inch, probe: probe))
            .contains("G31 Z-0.5000 F4.9"))
        // Inch machine, mm post: 4.99 in/min is 126.746 mm/min.
        let job = Self.job(.millimeter, spot: Vec2(150, 100))
        let mm = try Self.post([Self.cut("A", at: 25, job: job)],
                               profile: Self.profile(BuiltInPosts.avidMach4MM, probe: probe), job: job, units: .millimeter)
        #expect(mm.contains { $0.hasPrefix("G31 ") && $0.hasSuffix(" F126") })
    }

    @Test func travelFlooredWithEpsilon() throws {
        var probe = Self.mach4
        probe.plateThickness = 0.57; probe.probeTravel = 0.57
        #expect(try Self.post([Self.cut("A")], profile: Self.profile(BuiltInPosts.avidMach4Inch, probe: probe))
            .contains("G31 Z-0.5700 F5.0"))
        // A 25.4 mm travel and plate on an inch post: 25.4 / 25.4 must write 1.0000, not 0.9999.
        var mmMachine = BuiltInMachines.avidPRO6096
        mmMachine.units = .millimeter
        mmMachine.limits = MachineLimits(xTravel: 1524, yTravel: 2438.4, zTravel: 203.2, maxSpoilboardCut: 1.27)
        let mmProbe = ToolChangeProbe(parkX: 50, parkY: -50, parkZ: -10, topZ: 0, plateThickness: 25.4, plateSize: 76,
                                      probeFeed: 127, probeTravel: 25.4, controller: .mach4, mach4ZeroMacro: 199)
        #expect(try Self.post([Self.cut("A")], profile: Self.profile(BuiltInPosts.avidMach4Inch, machine: mmMachine, probe: mmProbe))
            .contains("G31 Z-1.0000 F5.0"))
    }

    @Test func g53ValuesTowardZero() throws {
        var mmMachine = BuiltInMachines.avidPRO6096
        mmMachine.units = .millimeter
        mmMachine.limits = MachineLimits(xTravel: 1524, yTravel: 2438.4, zTravel: 203.2, maxSpoilboardCut: 1.27)
        let probe = ToolChangeProbe(parkX: 201, parkY: -201, parkZ: -10, topZ: 0, plateThickness: 12.7, plateSize: 76,
                                    probeFeed: 127, probeTravel: 12.7, controller: .mach4, mach4ZeroMacro: 199)
        let lines = try Self.post([Self.cut("A")], profile: Self.profile(BuiltInPosts.avidMach4Inch, machine: mmMachine, probe: probe))
        #expect(lines.contains("G53 G0 X7.9133 Y-7.9133"))   // 201 mm = 7.913386 in
    }

    @Test func workOffsetIsSelectedAndZeroed() throws {
        var probe = Self.grbl
        probe.workOffset = 2
        let job = Self.job(.millimeter, spot: Vec2(150, 100))
        let lines = try Self.post([Self.cut("A", at: 10, job: job)],
                                  profile: Self.profile(BuiltInPosts.genericGRBLMM, machine: BuiltInMachines.genericGRBL, probe: probe),
                                  job: job, units: .millimeter)
        #expect(lines.contains("G90 G92.1 G55") && lines.contains("G10 L20 P2 Z12.000"))
    }

    @Test func everyG53XYAfterTopZ() throws {
        for lines in [try Self.post([Self.cut("A"), Self.cut("B", tool: PostFixtures.vBit, at: 5)])] {
            for (i, l) in lines.enumerated() where l.hasPrefix("G53 G0 X") { #expect(lines[i - 1] == "G53 G0 Z0.0000") }
        }
    }

    @Test func recoveryLineFollowsTheArcMode() throws {
        var abs = BuiltInPosts.avidMach4Inch
        abs.arcOutput = .absoluteIJ
        // Not a built-in post any more, so probing refuses: the arc word is checked through the builder's helper.
        #expect(ProgramBuilder.recoveryLine(profile: abs, workOffset: 1) == "G17 G40 G49 G80 G90 G94 G90.1 G20 G54")
        #expect(ProgramBuilder.recoveryLine(profile: BuiltInPosts.avidMach4MM, workOffset: 3)
                == "G17 G40 G49 G80 G90 G94 G91.1 G21 G56")
    }

    @Test func spotRapidAlwaysWritesXAndY() throws {
        // The first toolpath ends at X 6 (the spot's X): the spot rapid still names X.
        let lines = try Self.post([Self.cut("A", at: 5), Self.cut("B", tool: PostFixtures.vBit, at: 8)])
        #expect(lines.filter { $0 == "G0 X6.0000 Y4.0000" }.count == 2)
        let second = try #require(lines.lastIndex(of: "G0 X6.0000 Y4.0000"))
        #expect(lines[second - 1] == "G53 G0 Z0.0000")
    }

    @Test func lineNumbersOn() throws {
        var numbered = Self.profile(BuiltInPosts.avidMach4Inch)
        numbered.lineNumbers = true
        let lines = try Self.post([Self.cut("A")], profile: numbered)
        #expect(lines.contains { $0.hasSuffix(" G53 G0 Z0.0000") && $0.hasPrefix("N") })
        #expect(lines.contains { $0.hasSuffix(" M199 P0.5000") })
    }

    // MARK: Refusals

    @Test func refusals() {
        #expect(refusal(job: Self.job(spot: nil))?.contains("touch-off spot") == true)
        var g43 = Self.profile(BuiltInPosts.avidMach4Inch)
        g43.useToolLengthOffset = true
        #expect(refusal(profile: g43)?.contains("G43") == true)
        var bad = Self.mach4
        bad.mach4ZeroMacro = nil
        #expect(refusal(profile: Self.profile(BuiltInPosts.avidMach4Inch, probe: bad)) != nil)
        var deep = Self.job()
        deep.safeZ = 7.8   // 0.5 plate + 7.8 > 8 in of Z travel
        #expect(refusal(job: deep)?.contains("Z travel") == true)
        // The mm post writes feeds with no decimals.
        var slow = Self.mach4
        slow.probeFeed = 0.01   // 0.254 mm/min writes F0
        let job = Self.job(.millimeter, spot: Vec2(150, 100))
        #expect(refusal([Self.cut("A", at: 10, job: job)], profile: Self.profile(BuiltInPosts.avidMach4MM, probe: slow), job: job,
                        units: .millimeter)?.contains("feed") == true)
        var coarse = Self.profile(BuiltInPosts.avidMach4Inch)
        coarse.decimals = 0
        var thin = Self.mach4
        thin.plateThickness = 0.4; thin.probeTravel = 0.4
        coarse.toolChangeProbe = .on(thin)
        #expect(refusal(profile: coarse) != nil)
        var tiny = Self.job(.millimeter, spot: Vec2(150, 100))
        tiny.safeZ = 0.0004
        var g = Self.grbl
        g.plateThickness = 3; g.probeTravel = 3
        #expect(refusal([Self.cut("A", at: 10, job: tiny)],
                        profile: Self.profile(BuiltInPosts.genericGRBLMM, machine: BuiltInMachines.genericGRBL, probe: g),
                        job: tiny, units: .millimeter)?.contains("clear") == true)
        var refused = BuiltInMachines.avidPRO6096
        refused.probeRefusal = "Not set up here."
        #expect(refusal(profile: refused.applied(to: BuiltInPosts.avidMach4Inch)) == "Not set up here.")
        var twoSided = Self.job()
        twoSided.twoSided = TwoSidedSetup()
        #expect(refusal(job: twoSided)?.contains("two-sided") == true)
        var t300 = PostFixtures.endMill
        t300.number = 300
        let gjob = Self.job(.millimeter, spot: Vec2(150, 100))
        #expect(refusal([Self.cut("A", tool: t300, at: 10, job: gjob)],
                        profile: Self.profile(BuiltInPosts.genericGRBLMM, machine: BuiltInMachines.genericGRBL, probe: Self.grbl),
                        job: gjob, units: .millimeter)?.contains("255") == true)
    }

    @Test func withoutProbingNothingChanges() throws {
        let plain = try Self.post([Self.cut("A")], profile: BuiltInPosts.avidMach4Inch)
        #expect(plain.contains("T1 M6") && !plain.contains { $0.hasPrefix("G53") })
    }
}
