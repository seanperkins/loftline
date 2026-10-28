import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// Operator pauses (`Toolpath.pauseAfter`): where they land in the program, what they do to the
/// spindle and Z, and how the toolpath order and the validator treat them.
@Suite struct PostPauseTests {
    let endMill = PostFixtures.endMill
    let vBit = PostFixtures.vBit

    /// A short cut at depth 0.1 below the top; `from` is the start X.
    func cut(_ name: String, tool: Tool? = nil, from x: Double = 1, pause: PauseStep? = nil,
             zZero: ZZeroMode = .materialTop) -> Toolpath {
        let mc = MachineCoordinates(job: PostFixtures.job(zZero: zZero))
        let d = mc.z(depth: 0.1), safe = mc.safeZ
        var tp = Toolpath(name: name, kind: .profile, tool: tool ?? endMill, moves: [
            .rapid(to: Vec3(x, 1, safe)),
            .linear(to: Vec3(x, 1, d), feed: 30),
            .linear(to: Vec3(x + 1, 1, d), feed: 100),
            .rapid(to: Vec3(x + 1, 1, safe)),
        ])
        tp.pauseAfter = pause
        return tp
    }

    func post(_ tps: [Toolpath], zZero: ZZeroMode = .materialTop, approachHeight: Double? = nil,
              profile: PostProfile = BuiltInPosts.avidMach4Inch) throws -> [String] {
        let job = PostJob(name: "P", units: .inch, job: PostFixtures.job(zZero: zZero), toolpaths: tps,
                          approachHeight: approachHeight)
        return try TemplatePostProcessor(profile: profile).post(job).split(separator: "\n").map(String.init)
    }

    func index(of prefix: String, in lines: [String], after start: Int = 0) -> Int? {
        lines[start...].firstIndex { $0.hasPrefix(prefix) }
    }

    @Test func stopsTheSpindleShowsTheMessageThenStopsAndRestartsAfterwards() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Flip the part")), cut("B", from: 4)])
        let stop = try #require(index(of: "M0", in: lines))
        #expect(lines[stop - 1] == "(MSG, Flip the part)")
        #expect(lines[stop - 2] == "M5")
        #expect(lines[stop - 3] == "( Pause after toolpath: A )")
        // Then Z comes back up, the spindle restarts and waits before the next toolpath cuts.
        let b = try #require(index(of: "( Toolpath: B", in: lines))
        let restart = try #require(index(of: "M3 S", in: lines, after: stop))
        #expect(stop < restart && restart < b)
        #expect(lines[restart + 1] == "G4 P3")
        // Z is restated before any XY move after the stop.
        #expect(lines[stop + 1] == "G0 Z0.2000")
        // Nothing but the first program's own spindle start precedes the stop.
        #expect(lines[..<stop].filter { $0.hasPrefix("M3 S") }.count == 1)
    }

    @Test func optionalStopWritesM1() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)])
        #expect(lines.contains("M1"))
        #expect(!lines.contains("M0"))
    }

    @Test func optionalStopOnAGRBLPostWritesM0() throws {
        // GRBL ignores M1 (gnea/grbl gcode.c: "Optional stop not supported. Ignore."), so the stop would never happen (#115).
        var declared = BuiltInPosts.avidMach4Inch
        declared.id = "shop-grbl"
        declared.controller = .grbl
        for profile in [BuiltInPosts.genericGRBLMM, BuiltInPosts.genericGRBLInch, declared] {
            let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)],
                                 profile: profile)
            #expect(lines.contains("M0"), "\(profile.id)")
            #expect(!lines.contains("M1"), "\(profile.id)")
            #expect(lines.contains("(   after A: Check [M0] )"), "\(profile.id)")
        }
    }

    @Test func aMachineAdjustedGRBLPostStillWritesM0() throws {
        // Export posts with the machine's limits, rates and RPM range applied, so the post no longer equals the built-in.
        var m = BuiltInMachines.avidPRO6096
        m.rapidRate = 123; m.maxFeed = 456; m.minRPM = 5000; m.maxRPM = 20000
        for builtIn in [BuiltInPosts.genericGRBLMM, BuiltInPosts.genericGRBLInch] {
            let applied = m.applied(to: builtIn)
            #expect(applied != builtIn)
            #expect(!applied.honoursOptionalStop, "\(builtIn.id)")
            let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)],
                                 profile: applied)
            #expect(lines.contains("M0") && !lines.contains("M1"), "\(builtIn.id)")
        }
        // An edited dialect is no longer the built-in: it writes what its owner declared.
        var edited = m.applied(to: BuiltInPosts.genericGRBLMM)
        edited.footer.append("(edited)")
        #expect(edited.honoursOptionalStop)
    }

    @Test func optionalStopOnAnOthermillPostWritesM0() throws {
        // TinyG has no Optional Stop and treats M1 as M0 (#114): the post writes M0 and says the stop always happens. Judged by
        // id, so an edited post that keeps the id still writes M0 (unlike an edited GRBL post, judged by value).
        var m = BuiltInMachines.othermillPro
        m.maxRPM = 24000
        for builtIn in [BuiltInPosts.othermillInch, BuiltInPosts.othermillMM] {
            var edited = builtIn
            edited.footer.append("(edited)")
            for profile in [builtIn, m.applied(to: builtIn), edited] {
                #expect(!profile.honoursOptionalStop, "\(profile.id)")
                let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)],
                                     profile: BuiltInMachines.avidPRO6096.applied(to: profile))
                #expect(lines.contains("M0") && !lines.contains("M1"), "\(profile.id)")
                #expect(lines.contains("(   after A: Check [M0] )"), "\(profile.id)")
            }
        }
    }

    @Test func optionalStopOnBuildboticsAndCarbideMotionWritesM0() throws {
        // BB resumes an "Optional pause" at once (its control is hidden); Carbide Motion's "Sleep" is undocumented (#104, #105).
        for builtIn in [BuiltInPosts.onefinityBBInch, BuiltInPosts.onefinityBBMM, BuiltInPosts.carbideMotionInch,
                        BuiltInPosts.carbideMotionMM] {
            var edited = builtIn
            edited.footer.append("M5")
            for profile in [builtIn, BuiltInMachines.avidPRO6096.applied(to: builtIn), edited] {
                #expect(!profile.honoursOptionalStop, "\(profile.id)")
                let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)],
                                     profile: BuiltInMachines.avidPRO6096.applied(to: profile))
                #expect(lines.contains("M0") && !lines.contains("M1"), "\(profile.id)")
            }
        }
    }

    @Test func optionalStopKeepsM1WhereTheControllerHasTheSwitch() throws {
        for profile in [BuiltInPosts.avidMach4Inch, BuiltInPosts.linuxCNCInch] {
            #expect(profile.honoursOptionalStop, "\(profile.id)")
            let lines = try post([cut("A", pause: PauseStep(message: "Check", isOptionalStop: true)), cut("B", from: 4)],
                                 profile: profile)
            #expect(lines.contains("M1"), "\(profile.id)")
            // The header does not promise a wait the switch may skip.
            #expect(lines.contains("(   after A: Check [M1, stops only with Optional Stop on] )"), "\(profile.id)")
        }
        #expect(!BuiltInPosts.genericGRBLMM.honoursOptionalStop)
    }

    @Test func aPlainStopsHeaderIsUnchanged() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Flip")), cut("B", from: 4)])
        #expect(lines.contains("(   after A: Flip [M0] )"))
    }

    @Test func noStopAfterTheLastToolpath() throws {
        let lines = try post([cut("A"), cut("B", from: 4, pause: PauseStep(message: "Last"))])
        #expect(!lines.contains("M0"))
        #expect(!lines.contains { $0.contains("MSG") })
        #expect(!lines.contains { $0.contains("Pauses (") })
    }

    @Test func aToolChangeAfterTheStopDoesTheReEntry() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Swap")), cut("B", tool: vBit, from: 4)])
        let stop = try #require(index(of: "M0", in: lines))
        let change = try #require(lines[stop...].firstIndex { $0.contains("M6") })
        // Only the tool change's own re-entry between the stop and the next cut: no extra Z move before M5.
        #expect(lines[(stop + 1)..<change].allSatisfy { $0.hasPrefix("M5") || $0.hasPrefix("(Change") })
        #expect(lines[change...].contains { $0.hasPrefix("M3 S") })
    }

    @Test(arguments: [ZZeroMode.materialTop, ZZeroMode.spoilboard])
    func retractsToSafeZBeforeStopping(zZero: ZZeroMode) throws {
        // A generator that ends the toolpath inside the cut: the post lifts before M5/M0.
        let mc = MachineCoordinates(job: PostFixtures.job(zZero: zZero))
        var low = cut("A", pause: PauseStep(message: "Flip"), zZero: zZero)
        low.moves.removeLast()
        let lines = try post([low, cut("B", from: 4, zZero: zZero)], zZero: zZero)
        let stop = try #require(index(of: "M0", in: lines))
        let safe = NumberFormat.fixed(mc.safeZ, decimals: 4)
        #expect(lines[stop - 4] == "G0 Z\(safe)")
        #expect(lines[stop + 1] == "G0 Z\(safe)")
    }

    @Test(arguments: [ZZeroMode.materialTop, ZZeroMode.spoilboard])
    func crossesToTheNextToolpathAtTheApproachHeightAfterAStop(zZero: ZZeroMode) throws {
        // A clamp taller than safe Z: the stop leaves the position unknown, so the traverse to the
        // next toolpath happens at the approach height, as after a tool change.
        let mc = MachineCoordinates(job: PostFixtures.job(zZero: zZero))
        let approach = mc.z(aboveTop: 0.9)
        let lines = try post([cut("A", pause: PauseStep(message: "Clamp"), zZero: zZero), cut("B", from: 4, zZero: zZero)],
                             zZero: zZero, approachHeight: 0.9)
        let stop = try #require(index(of: "M0", in: lines))
        let up = NumberFormat.fixed(approach, decimals: 4)
        #expect(lines[stop + 1] == "G0 Z\(up)")
        #expect(lines[stop + 2].hasSuffix("X4.0000 Y1.0000"))
        let restart = try #require(index(of: "M3 S", in: lines, after: stop))
        #expect(restart > stop + 2)
    }

    @Test func aMessageCannotStartANewLine() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Flip\nG0 Z-1 (now)\r\nM3")), cut("B", from: 4)])
        let msg = try #require(lines.first { $0.hasPrefix("(MSG") })
        #expect(msg == "(MSG, Flip G0 Z-1 [now]  M3)")
        #expect(!lines.contains("G0 Z-1 (now)"))
        #expect(!lines.contains("M3"))
    }

    @Test func anEmptyMessageNamesTheToolpath() throws {
        let lines = try post([cut("Pocket 1", pause: PauseStep()), cut("B", from: 4)])
        #expect(lines.contains("(MSG, Paused after Pocket 1)"))
    }

    @Test func theHeaderListsThePauses() throws {
        let lines = try post([cut("A", pause: PauseStep(message: "Flip the part")), cut("B", from: 4)])
        #expect(lines.contains("( Pauses - the machine waits for Cycle Start: )"))
        #expect(lines.contains("(   after A: Flip the part [M0] )"))
    }

    @Test func aProfileCanReplaceTheTemplate() throws {
        var p = BuiltInPosts.avidMach4Inch
        p.pause = ["G0 Z{SAFE_Z}", "M5", "M117 {MESSAGE}", "{STOP}"]
        let lines = try post([cut("A", pause: PauseStep(message: "Hi")), cut("B", from: 4)], profile: p)
        let stop = try #require(index(of: "M0", in: lines))
        #expect(lines[(stop - 3)...stop] == ["G0 Z0.2000", "M5", "M117 Hi", "M0"])
    }

    @Test func semicolonPostsGetASemicolonMessage() throws {
        var p = BuiltInPosts.genericGRBLMM
        p.commentStyle = .semicolon
        #expect(p.pauseLines == ["M5", "; {MESSAGE}", "{STOP}"])
        #expect(BuiltInPosts.avidMach4Inch.pauseLines == ["M5", "(MSG, {MESSAGE})", "{STOP}"])
    }

    @Test func savedPostsWithoutAPauseTemplateStillLoad() throws {
        let p = BuiltInPosts.avidMach4Inch
        let json = try p.toJSON()
        #expect(!String(decoding: json, as: UTF8.self).contains("\"pause\""))
        #expect(try PostProfile.fromJSON(json).pause == nil)
        var custom = p
        custom.pause = ["M0"]
        #expect(try PostProfile.fromJSON(custom.toJSON()).pause == ["M0"])
    }

    @Test func programsWithoutPausesAreUnchanged() throws {
        let plain = try post([cut("A"), cut("B", from: 4)])
        #expect(!plain.contains { $0.contains("M0") || $0.contains("MSG") || $0.contains("Pause") })
    }

    // MARK: Validator

    @Test func theProgramWeWriteDoesNotTripTheStopChecks() throws {
        let tps = [cut("A", pause: PauseStep(message: "Flip")), cut("B", from: 4)]
        let text = try post(tps).joined(separator: "\n")
        let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
        #expect(GCodeValidator.errors(in: v.validate(gcode: text)).isEmpty)
        #expect(!v.validate(gcode: text).contains { $0.message.contains("stops") })
    }

    @Test func warnsWhenAStopLeavesTheSpindleRunning() {
        let text = "G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\nM0\nG0 X2\nM5\nM30\n"
        let issues = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
            .validate(gcode: text)
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("Program stops (M0) with the spindle running") })
    }

    @Test func warnsWhenAStopLeavesTheToolBelowSafeZ() {
        let text = "G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\nG1 Z-0.1 F30\nM5\nM1\nM30\n"
        let issues = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
            .validate(gcode: text)
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("Program stops (M1) with the tool below safe Z") })
    }

    @Test func theStopIsJudgedAfterTheWholeBlock() {
        // Controllers run a block's spindle word and motion before the stop, whatever the word order.
        let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
        func stops(_ body: String) -> [String] {
            v.validate(gcode: "G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\n\(body)\nG0 Z0.2\nM5\nM30\n")
                .filter { $0.message.contains("stops") }.map(\.message)
        }
        // "M0 M5": the spindle is off when the machine stops.
        #expect(stops("M0 M5").isEmpty)
        // "M5 M0 M3 S18000": on again before the stop.
        #expect(stops("M5\nM0 M3 S18000") == ["Program stops (M0) with the spindle running"])
        // The block's own descent happens first: the stop is at Z0.1, below safe Z 0.2.
        #expect(stops("M5\nG0 Z0.1 M0") == ["Program stops (M0) with the tool below safe Z"])
        // And its own retract clears it.
        #expect(stops("G1 Z-0.1 F30\nM5\nG0 Z0.2 M1").isEmpty)
    }

    @Test func aStopBeforeAnyMoveIsFine() {
        // GRBL's first tool change writes M5 / comment / M0 before anything has moved.
        let text = "G20\nG90\nM5\nM0\nG0 Z0.2\nM30\n"
        let issues = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
            .validate(gcode: text)
        #expect(!issues.contains { $0.message.contains("stops") })
    }

    // MARK: Order

    func op(_ id: String) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-00000000\(id)")! }

    /// Two toolpaths of tool 1 around one of tool 6, far apart so only the pause can hold them.
    func threeToolpaths(pauseOn: Int?) -> [Toolpath] {
        var a = cut("A", from: 1), b = cut("B", tool: vBit, from: 20), c = cut("C", from: 40)
        a.kind = .pocket; b.kind = .pocket; c.kind = .pocket
        a.operationID = op("0001"); b.operationID = op("0002"); c.operationID = op("0003")
        var all = [a, b, c]
        if let pauseOn { all[pauseOn].pauseAfter = PauseStep(message: "x") }
        return all
    }

    @Test func groupingMergesAcrossTheMiddleToolpathWithoutAPause() {
        #expect(ToolpathOrdering.groupedByTool(threeToolpaths(pauseOn: nil)).map(\.name) == ["A", "C", "B"])
    }

    @Test func aToolpathNeverJumpsAheadOfAPause() {
        // B (V-bit) is followed by the pause; C must stay after it.
        #expect(ToolpathOrdering.groupedByTool(threeToolpaths(pauseOn: 1)).map(\.name) == ["A", "B", "C"])
    }

    @Test func aToolpathWithAPauseDoesNotJumpAheadOfOthers() {
        // C carries the pause; hopping ahead of B would put B after the stop.
        #expect(ToolpathOrdering.groupedByTool(threeToolpaths(pauseOn: 2)).map(\.name) == ["A", "B", "C"])
    }
}
