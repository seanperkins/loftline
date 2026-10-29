import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

private func validate(_ gcode: String, zZero: ZZeroMode = .materialTop,
                      profile: PostProfile = BuiltInPosts.avidMach4Inch, units: LengthUnit = .inch) -> [GCodeIssue] {
    GCodeValidator(profile: profile, job: PostFixtures.job(zZero: zZero), units: units).validate(gcode: gcode)
}

/// Wraps motion lines in a well-formed program (units, spindle on, feed, footer).
private func program(_ body: String, spindle: Bool = true, safe: String = "0.2") -> String {
    """
    ( test )
    G20
    G90
    G0 Z\(safe)
    \(spindle ? "M3 S18000" : "")
    \(body)
    G0 Z\(safe)
    M5
    M30
    """
}

private func errors(_ issues: [GCodeIssue]) -> [String] { GCodeValidator.errors(in: issues).map(\.message) }

private func has(_ issues: [GCodeIssue], _ fragment: String, _ severity: GCodeIssue.Severity = .error) -> Bool {
    issues.contains { $0.severity == severity && $0.message.contains(fragment) }
}

@Test func cleanProgramHasNoIssues() {
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.25 F30\nX3 F100\nG3 X3 Y3 I0 J1\nG0 Z0.2"))
    #expect(issues.isEmpty, "\(issues)")
}

@Test func reportsTravelBeyondMachineLimits() {
    let issues = validate(program("G0 X0 Y0\nG0 X61 Y10"))
    #expect(has(issues, "X travel 61.0000 in exceeds"))
    #expect(!has(issues, "Y travel"))
}

@Test func arcExtentsCountTowardsTravel() {
    // Full circle of radius 30.5 around (30.5, 40): spans 61" in X — only visible via I/J.
    let issues = validate(program("G0 X0 Y40\nG1 Z-0.1 F30\nG2 X0 Y40 I30.5 J0 F100"))
    #expect(has(issues, "X travel"))
    #expect(!has(issues, "Y travel"))   // 61 < 96
}

@Test func reportsCutBelowAllowedDepthMaterialTopZero() {
    // 0.75 thick + 0.05 allowance: -0.79 is fine, -0.85 is not.
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.79 F30")).isEmpty)
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.85 F30"))
    #expect(has(issues, "below the allowed depth Z-0.8000"))
    #expect(issues.first?.line == 7)
}

@Test func reportsCutBelowAllowedDepthSpoilboardZero() {
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.04 F30", safe: "0.95"), zZero: .spoilboard).isEmpty)
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30", safe: "0.95"), zZero: .spoilboard)
    #expect(has(issues, "below the allowed depth Z-0.0500"))
}

@Test func maxCutThroughIsConfigurable() {
    var p = BuiltInPosts.avidMach4Inch
    p.limits.maxSpoilboardCut = 0.1
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.84 F30"), profile: p).isEmpty)
}

@Test func reportsRapidThroughMaterial() {
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 X2 Y2"))
    #expect(has(issues, "Rapid XY move inside the material"))
}

@Test func warnsOnRapidBelowSafeZAboveMaterial() {
    let issues = validate(program("G0 X1 Y1\nG0 Z0.05\nG0 X2"))
    #expect(errors(issues).isEmpty)
    #expect(has(issues, "below safe Z", .warning))
}

@Test func warnsOnRapidPlungeIntoMaterial() {
    let issues = validate(program("G0 X1 Y1\nG0 Z-0.1"))
    #expect(has(issues, "Rapid plunge", .warning))
}

@Test func reportsCuttingWithSpindleOff() {
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30", spindle: false))
    #expect(has(issues, "spindle off"))
    // Feed moves in the air without the spindle are not flagged.
    #expect(validate(program("G0 X1 Y1\nG1 Z0.1 F30", spindle: false)).isEmpty)
}

@Test func spindleStopMidProgramIsDetected() {
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nM5\nX2"))
    #expect(has(issues, "spindle off"))
}

@Test func reportsMissingFeed() {
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1\nX2\nX3"))
    #expect(has(issues, "without a feed rate"))
    #expect(issues.first { $0.message.contains("feed rate") }?.message.hasSuffix("(2 more)") == true)
}

@Test func reportsZeroFeedAndExcessiveFeed() {
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F0")), "zero or negative feed"))
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F900")), "exceeds the machine maximum", .warning))
}

@Test func reportsSpindleSpeedOutOfRange() {
    let issues = validate("G20\nM3 S30000\nM5\nM30")
    #expect(has(issues, "S30000 outside 6000"))
}

@Test func reportsArcRadiusMismatch() {
    let issues = validate(program("G0 X2 Y1\nG1 Z-0.1 F30\nG2 X0 Y1.5 I-1 J0"))
    #expect(has(issues, "radii differ"))
}

@Test func absoluteArcCentresFollowProfile() {
    var p = BuiltInPosts.avidMach4Inch
    p.arcOutput = .absoluteIJ
    #expect(validate(program("G0 X2 Y1\nG1 Z-0.1 F30\nG2 X0 Y1 I1 J1"), profile: p).isEmpty)
}

@Test func warnsOnMissingUnitsAndEnd() {
    let issues = validate("G0 Z0.2\nG0 X1 Y1")
    #expect(has(issues, "never sets units", .warning))
    #expect(has(issues, "M30/M2", .warning))
    #expect(errors(issues).isEmpty)
}

@Test func warnsWhenXYRapidPrecedesKnownZ() {
    let issues = validate("G20\nG0 X1 Y1\nM30")
    #expect(has(issues, "before the Z height is known", .warning))
}

@Test func checksInTheProgramsDeclaredUnits() {
    // Metric program with an inch profile and inch job: -19.5 mm (0.768") is fine, -21 mm is not.
    #expect(errors(validate("G21\nG0 Z5\nM3 S18000\nG0 X10 Y10\nG1 Z-19.5 F500\nG0 Z5\nM30")).isEmpty)
    let issues = validate("G21\nG0 Z5\nM3 S18000\nG0 X10 Y10\nG1 Z-21 F500\nG0 Z5\nM30")
    #expect(has(issues, "below the allowed depth"))
    #expect(has(issues, "differ from the profile", .warning))
}

@Test func parserHandlesCommentsLineNumbersAndCase() {
    let r = GCodeParser.parse("N10 g1 x1.5 (move) y-2 ; tail\n(only comment)\n%\nT1 M6", comments: .standard)
    #expect(r.blocks.count == 2)
    #expect(r.blocks[0].value("X") == 1.5 && r.blocks[0].value("Y") == -2 && r.blocks[0].has("G", 1))
    #expect(r.blocks[1].line == 4 && r.blocks[1].has("M", 6))
    #expect(r.garbage.isEmpty)
}

// MARK: Toolpath-level validation

@Test func toolpathValidationFlagsDepthRapidsAndTravel() {
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
    #expect(v.validate(toolpaths: PostFixtures.toolpaths()).isEmpty)

    let bad = Toolpath(name: "bad", kind: .profile, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(0, 0, 0.2)),
        .linear(to: Vec3(0, 0, -1.0), feed: 30),        // through the spoilboard
        .rapid(to: Vec3(70, 0, -1.0)),                   // rapid in material, beyond X travel
    ])
    let issues = v.validate(toolpaths: [bad])
    #expect(has(issues, "below the allowed depth"))
    #expect(has(issues, "Rapid XY move inside the material"))
    #expect(has(issues, "X travel"))
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func toolpathValidationRefusesCutsDeeperThanTheFlutes(mode: ZZeroMode) {
    // The 1/8 in end mill has a 0.5 in flute: a 0.6 in cut rubs the shank on the wall and is an
    // error, whatever a hand-edited tool or depth says; 0.5 in is fine.
    let job = PostFixtures.job(zZero: mode)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let eighth = ToolLibrary.seeded.tools[1]
    let c = MachineCoordinates(job: job)
    func tp(_ depth: Double) -> Toolpath {
        Toolpath(name: "deep", kind: .pocket, tool: eighth, moves: [
            .rapid(to: Vec3(1, 1, c.safeZ)), .linear(to: Vec3(1, 1, c.z(depth: depth)), feed: 30),
            .linear(to: Vec3(2, 1, c.z(depth: depth)), feed: 60), .rapid(to: Vec3(2, 1, c.safeZ)),
        ])
    }
    let issues = v.validate(toolpaths: [tp(0.6)])
    #expect(has(issues, "Toolpath 'deep' cuts 0.6000 in below the material top with a 0.5000 in flute (\(eighth.name)); the shank rubs the wall above the flutes"))
    #expect(!v.validate(toolpaths: [tp(0.5)]).contains { $0.message.contains("flute") })
    // Material already cleared above the cut counts: a 0.9 in cut from a 0.5 in start depth fits.
    var cleared = tp(0.9); cleared.clearedDepth = 0.5
    #expect(!v.validate(toolpaths: [cleared]).contains { $0.message.contains("flute") })
}

@Test func toolpathValidationChecksRPMAndFeedAndUnits() {
    let mm = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job().scaled(by: 25.4),
                            units: .millimeter)
    let tp = Toolpath(name: "fast", kind: .profile, tool: PostFixtures.endMill, spindleRPM: 26000, moves: [
        .rapid(to: Vec3(0, 0, 5)),
        .linear(to: Vec3(0, 0, -19.5), feed: 0),
        .rapid(to: Vec3(0, 0, 5)),
    ])
    let issues = mm.validate(toolpaths: [tp])
    #expect(has(issues, "S26000"))
    #expect(has(issues, "zero or negative feed"))
    #expect(!has(issues, "allowed depth"))
    // The tool's 1 in flute is 25.4 mm here: 19.5 mm fits, 30 mm does not.
    #expect(!has(issues, "flute"))
    let deep = Toolpath(name: "deep", kind: .profile, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(0, 0, 5)), .linear(to: Vec3(0, 0, -30), feed: 500), .rapid(to: Vec3(0, 0, 5)),
    ])
    #expect(has(mm.validate(toolpaths: [deep]), "cuts 30.000 mm below the material top with a 25.400 mm flute"))
}

@Test func flagsInlayPocketAndPlugInOneProgram() {
    let tool = ToolLibrary.seeded.tools[5]
    func part(_ name: String) -> Toolpath {
        Toolpath(name: name, kind: .inlay, tool: tool,
                 moves: [.rapid(to: Vec3(1, 1, 0.5)), .linear(to: Vec3(1, 1, -0.1), feed: 20),
                         .rapid(to: Vec3(1, 1, 0.5))],
                 metadata: ["part": name])
    }
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(zZero: .materialTop), units: .inch)
    #expect(has(v.validate(toolpaths: [part("female"), part("male")]), "same program"))
    #expect(!has(v.validate(toolpaths: [part("female")]), "same program"))
}

@Test func flagsBothReliefSidesInOneProgram() {
    let tool = ToolLibrary.seeded.tools[0]
    func side(_ name: String?) -> Toolpath {
        Toolpath(name: name ?? "one", kind: .relief3D, tool: tool,
                 moves: [.rapid(to: Vec3(1, 1, 0.5)), .linear(to: Vec3(1, 1, -0.1), feed: 20),
                         .rapid(to: Vec3(1, 1, 0.5))],
                 metadata: name.map { ["side": $0] } ?? [:])
    }
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(zZero: .materialTop), units: .inch)
    #expect(has(v.validate(toolpaths: [side("top"), side("bottom")]), "same program"))
    #expect(!has(v.validate(toolpaths: [side("top"), side("top")]), "same program"))
    #expect(!has(v.validate(toolpaths: [side("bottom"), side(nil)]), "same program"))
}

// MARK: Peck drilling re-entry

/// Peck drilling feeds a peck, retracts, rapids back down to just above the bottom of the hole and
/// feeds the next peck. Those rapids only move through air and must not be reported.
@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func allowsRapidReEntryIntoADrilledHole(mode: ZZeroMode) {
    let mc = MachineCoordinates(job: PostFixtures.job(zZero: mode))
    func z(_ depth: Double) -> String { String(format: "%.4f", mc.z(depth: depth)) }
    let retract = z(-0.05)
    let pecks = """
    G0 X1 Y1
    G0 Z\(retract)
    G1 Z\(z(0.1)) F30
    G0 Z\(retract)
    G0 Z\(z(0.08))
    G1 Z\(z(0.2)) F30
    G0 Z\(retract)
    G0 Z\(z(0.18))
    G1 Z\(z(0.3)) F30
    """
    let issues = validate(program(pecks, safe: String(format: "%.4f", mc.safeZ)), zZero: mode)
    #expect(issues.isEmpty, "\(issues)")
}

@Test func rapidMayTouchTheHoleBottomButNotPassIt() {
    // Exactly the bottom is air the tool has been in; one eps (0.0005 in) below it is not: the rule
    // has no slack.
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.05\nG0 Z-0.1")).isEmpty)
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.05\nG0 Z-0.1005")), "Rapid plunge", .warning))
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.05\nG0 Z-0.12")), "Rapid plunge", .warning))
}

@Test func rapidIntoTheMaterialAtAnotherXYStillWarns() {
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.2\nG0 X2\nG0 Z-0.08")), "Rapid plunge", .warning))
}

@Test func onlyTheLastHoleIsRemembered() {
    // Back at the first hole after visiting a second XY: the checker gives the safe answer.
    let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.2\nG0 X2\nG0 X1\nG0 Z-0.08"))
    #expect(has(issues, "Rapid plunge", .warning))
}

@Test func aRapidWithinEpsOfTheLastPositionButNotOfTheHoleWarns() {
    // Two sub-eps steps are each "no XY move", yet together leave the hole by more than eps.
    let steps = "G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.2\nG0 X1.0004\nG0 X1.0008\nG0 Z-0.05"
    #expect(has(validate(program(steps)), "Rapid plunge", .warning))
}

@Test func theHoleKeepsTheXYItWasDrilledAt() {
    // Plunges in sub-eps steps deepen the hole but do not walk it sideways: 0.0008 in from the first
    // plunge is outside eps of the hole, whatever the last plunge's XY was.
    let steps = "G0 X1 Y1\nG1 Z-0.1 F30\nG0 X1.0004\nG1 Z-0.11 F30\nG0 Z0.05\nG0 X1.0008\nG0 Z-0.1"
    #expect(has(validate(program(steps)), "Rapid plunge", .warning))
}

@Test func onlyPlungesDrillHoles() {
    // A horizontal cut through X2, or a ramp down to it, does not make X2 a hole a rapid may drop into.
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nX2 F100\nG0 Z0.2\nG0 Z-0.05")), "Rapid plunge", .warning))
    #expect(has(validate(program("G0 X1 Y1\nG1 X2 Z-0.1 F30\nG0 Z0.2\nG0 Z-0.05")), "Rapid plunge", .warning))
}

@Test func feedBeforeAnyXYDrillsNothing() {
    // The start XY of the first feed is a guess (the program never set X or Y), so it is no hole,
    // whether the feed is a line or an arc.
    #expect(has(validate(program("G1 Z-0.1 F30\nG0 Z0.2\nG0 Z-0.08")), "Rapid plunge", .warning))
    #expect(has(validate(program("G2 Z-0.1 I0.1 F30\nG0 Z0.2\nG0 Z-0.08")), "Rapid plunge", .warning))
}

@Test func feedsThatCannotRunOrGoUpLeaveTheHole() {
    // A plunge without a feed rate, or with F0, is an error and drills nothing; an upward feed and an
    // arc leave the hole too, so the rapid back down is reported.
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1\nG0 Z0.2\nG0 Z-0.08")), "Rapid plunge", .warning))
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F0\nG0 Z0.2\nG0 Z-0.08")), "Rapid plunge", .warning))
    #expect(has(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG1 Z0.1 F30\nG0 Z-0.08")), "Rapid plunge", .warning))
    // A helix ends where it started and goes down, but it clears a ring, not the column at its start.
    let helix = "G0 X1 Y1\nG1 Z-0.1 F30\nG3 X1 Y1 Z-0.2 I0.5 J0 F60\nG0 Z0.2\nG0 Z-0.08"
    #expect(has(validate(program(helix)), "Rapid plunge", .warning))
}

@Test func anyCodeOtherThanAPlainMoveForgetsTheHole() {
    // One rule: the hole survives only blocks made of G0–G3 with axis, arc, feed and line-number
    // words. Tool changes and stops (a different bit may not fit), frame shifts and reference returns
    // (the same XY words name another place), and words the rule never heard of (spindle, coolant,
    // dwell, tool length, distance mode, a bare H or D offset) all forget it, each here on its own
    // line with nothing else between the plunge and the rapid back down.
    let codes = ["T2 M6", "M6", "M0", "M1", "T2",
                 "G92 X1 Y1", "G92.1", "G55", "G59", "G10 L2 P1 X0 Y0", "G53 G0 X1 Y1", "G28", "G30 X1 Y1",
                 "M3 S18000", "S12000", "M8", "G4 P0.5", "G43 H1", "G90", "H2", "G0 Z0.05 D1"]
    for code in codes {
        let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.05\n\(code)\nG0 Z-0.08"))
        #expect(has(issues, "Rapid plunge", .warning), "after \(code): \(issues)")
    }
    // A feed rate, a line number or a comment is part of a plain move: the hole stays.
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nN10 G0 Z0.05\nF40\n( peck 2 )\nN11 G0 Z-0.08")).isEmpty)
    // The motion of a block runs before its stop, so a plunge sharing a line with M0 drills before
    // the tool may change: the hole is forgotten after that block, not only before it.
    let shared = validate(program("G0 X1 Y1\nG1 Z-0.1 F30 M0\nG0 Z0.05\nG0 Z-0.08"))
    #expect(has(shared, "Rapid plunge", .warning), "\(shared)")
    // And a frame change or tool word applies to the motion on its own line, so the hole is
    // forgotten before that block's rapid, not only after it.
    for same in ["G55 G0 Z-0.08", "T2 G0 Z-0.08"] {
        let issues = validate(program("G0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.05\n\(same)"))
        #expect(has(issues, "Rapid plunge", .warning), "\(same): \(issues)")
    }
}

@Test func aShallowerPlungeKeepsTheDeepestZ() {
    // The hole is as deep as the tool has ever fed there, not as deep as the last plunge.
    #expect(validate(program("G0 X1 Y1\nG1 Z-0.2 F30\nG0 Z0.05\nG1 Z-0.1 F30\nG0 Z0.05\nG0 Z-0.18")).isEmpty)
}

@Test func grblStopToolChangeForgetsTheHoleInMillimetres() {
    // The GRBL post has no M6: it stops with M0 for a manual tool change. Also the only mm case.
    let job = PostFixtures.job().scaled(by: 25.4)
    let v = GCodeValidator(profile: BuiltInPosts.genericGRBLMM, job: job, units: .millimeter)
    func run(_ body: String) -> [GCodeIssue] {
        v.validate(gcode: "G21\nG90\nG0 Z5.08\nM3 S18000\n\(body)\nG0 Z5.08\nM5\nM2\n")
    }
    let pecks = "G0 X25 Y25\nG0 Z1\nG1 Z-3 F500\nG0 Z1\nG0 Z-2.5\nG1 Z-6 F500"
    #expect(run(pecks).isEmpty, "\(run(pecks))")
    // The bottom itself is allowed; one eps (0.01 mm) past it is not.
    #expect(run("G0 X25 Y25\nG1 Z-3 F500\nG0 Z1\nG0 Z-3").isEmpty)
    #expect(has(run("G0 X25 Y25\nG1 Z-3 F500\nG0 Z1\nG0 Z-3.01"), "Rapid plunge", .warning))
    let changed = run("G0 X25 Y25\nG1 Z-3 F500\nG0 Z5.08\nM5\n(Change to Tool: 12 mm)\nM0\nM3 S18000\nG0 Z1\nG0 Z-2.5")
    #expect(has(changed, "Rapid plunge", .warning), "\(changed)")
}

@Test func absurdCoordinatesDoNotTrapTheChecker() {
    // Nothing in the checker may trap on a coordinate the parser accepts, however large.
    let issues = validate(program("G0 X10000000000000000000 Y0\nG1 Z-0.1 F30\nG0 Z0.2\nG0 Z-0.05"))
    #expect(has(issues, "X travel"))
}

// MARK: Toolpath check

private func drillMoves(_ p: Vec2, mc: MachineCoordinates, pecks: [Double], retractAbove: Double = 0.05) -> [Move] {
    let retract = Vec3(p.x, p.y, mc.z(aboveTop: retractAbove))
    var moves: [Move] = [.rapid(to: Vec3(p.x, p.y, mc.safeZ)), .rapid(to: retract)]
    var cleared = 0.0
    for d in pecks {
        if cleared > 0 { moves.append(.rapid(to: Vec3(p.x, p.y, mc.z(depth: cleared - 0.02)))) }
        moves.append(.linear(to: Vec3(p.x, p.y, mc.z(depth: d)), feed: 30))
        cleared = d
        if d != pecks.last { moves.append(.rapid(to: retract)) }
    }
    moves.append(.rapid(to: Vec3(p.x, p.y, mc.safeZ)))
    return moves
}

private func toolpath(_ name: String, tool: Tool, _ moves: [Move]) -> Toolpath {
    Toolpath(name: name, kind: .drill, tool: tool, moves: moves)
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func toolpathCheckAcceptsPeckDrilling(mode: ZZeroMode) {
    let job = PostFixtures.job(zZero: mode)
    let mc = MachineCoordinates(job: job)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let two = drillMoves(Vec2(2, 2), mc: mc, pecks: [0.1, 0.2]) + drillMoves(Vec2(4, 2), mc: mc, pecks: [0.1, 0.2, 0.3])
    let issues = v.validate(toolpaths: [toolpath("Drill", tool: PostFixtures.endMill, two)])
    #expect(issues.isEmpty, "\(issues)")
}

@Test(arguments: [ZZeroMode.materialTop, .spoilboard])
func toolpathCheckRejectsARapidPastTheHoleBottom(mode: ZZeroMode) {
    let job = PostFixtures.job(zZero: mode)
    let mc = MachineCoordinates(job: job)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let p = Vec2(2, 2)
    let moves = drillMoves(p, mc: mc, pecks: [0.1]).dropLast()
        + [.rapid(to: Vec3(p.x, p.y, mc.z(aboveTop: 0.05))), .rapid(to: Vec3(p.x, p.y, mc.z(depth: 0.15)))]
    let issues = v.validate(toolpaths: [toolpath("Drill", tool: PostFixtures.endMill, Array(moves))])
    #expect(has(issues, "Rapid plunge", .warning), "\(issues)")
}

@Test func toolpathCheckForgetsTheHoleWhenTheToolChangesOrTheMachineStops() {
    // The post writes a tool change only where the tool differs, and a stop where a toolpath pauses
    // after itself; the check forgets the hole there and only there, so the same tool may come back
    // down its own hole from the next toolpath.
    let job = PostFixtures.job()
    let mc = MachineCoordinates(job: job)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let p = Vec2(2, 2)
    let first = drillMoves(p, mc: mc, pecks: [0.1])
    let reenter: [Move] = [.rapid(to: Vec3(p.x, p.y, mc.z(aboveTop: 0.05))), .rapid(to: Vec3(p.x, p.y, mc.z(depth: 0.08))),
                           .linear(to: Vec3(p.x, p.y, mc.z(depth: 0.2)), feed: 30), .rapid(to: Vec3(p.x, p.y, mc.safeZ))]
    let sameTool = v.validate(toolpaths: [toolpath("A", tool: PostFixtures.endMill, first),
                                          toolpath("B", tool: PostFixtures.endMill, reenter)])
    #expect(sameTool.isEmpty, "\(sameTool)")
    let otherTool = v.validate(toolpaths: [toolpath("A", tool: PostFixtures.endMill, first),
                                           toolpath("B", tool: PostFixtures.vBit, reenter)])
    #expect(has(otherTool, "Rapid plunge", .warning), "\(otherTool)")
    var paused = toolpath("A", tool: PostFixtures.endMill, first)
    paused.pauseAfter = PauseStep(message: "Add clamps")
    let afterPause = v.validate(toolpaths: [paused, toolpath("B", tool: PostFixtures.endMill, reenter)])
    #expect(has(afterPause, "Rapid plunge", .warning), "\(afterPause)")
}

@Test func toolpathCheckForgetsTheHoleAtADwell() {
    // A dwell posts as G4, which the G-code check treats as not a plain move; the toolpath check
    // agrees, so a rapid back down after a dwell warns in both.
    let job = PostFixtures.job()
    let mc = MachineCoordinates(job: job)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let p = Vec2(2, 2)
    func issues(dwell seconds: Double) -> [GCodeIssue] {
        let moves = drillMoves(p, mc: mc, pecks: [0.1]).dropLast()
            + [.dwell(seconds: seconds), .rapid(to: Vec3(p.x, p.y, mc.z(aboveTop: 0.05))),
               .rapid(to: Vec3(p.x, p.y, mc.z(depth: 0.08))), .rapid(to: Vec3(p.x, p.y, mc.safeZ))]
        return v.validate(toolpaths: [toolpath("Drill", tool: PostFixtures.endMill, Array(moves))])
    }
    #expect(has(issues(dwell: 0.5), "Rapid plunge", .warning), "\(issues(dwell: 0.5))")
    // The writer emits nothing for a dwell of no length, so neither check sees a stop there.
    #expect(issues(dwell: 0).isEmpty, "\(issues(dwell: 0))")
}

@Test func toolpathCheckSurvivesANonFiniteHoleCentre() {
    // The exporter validates toolpaths before the post refuses a NaN move, so nothing in the checker
    // may trap on a non-finite coordinate either.
    let job = PostFixtures.job()
    let mc = MachineCoordinates(job: job)
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: job, units: .inch)
    let moves = drillMoves(Vec2(.nan, 2), mc: mc, pecks: [0.1, 0.2])
    _ = v.validate(toolpaths: [toolpath("Drill", tool: PostFixtures.endMill, moves)])
}
