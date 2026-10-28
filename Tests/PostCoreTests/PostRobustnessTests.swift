import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

private let tool = PostFixtures.endMill

private func post(_ tps: [Toolpath], profile: PostProfile = BuiltInPosts.avidMach4Inch) throws -> String {
    try TemplatePostProcessor(profile: profile).post(PostJob(name: "T", units: .inch, job: PostFixtures.job(), toolpaths: tps))
}

private func validate(_ gcode: String) -> [GCodeIssue] {
    GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch).validate(gcode: gcode)
}

private func warns(_ issues: [GCodeIssue], _ fragment: String) -> Bool {
    issues.contains { $0.severity == .warning && $0.message.contains(fragment) }
}

// MARK: Names

@Test func controlCharactersInNamesCannotStartANewBlock() throws {
    #expect(PostProfile.asciiOnly("Flat\nG0 Z-5\r\tx\u{7F}") == "Flat G0 Z-5  x ")
    var evil = tool
    evil.name = "Flat\nG0 Z-5"
    let tp = Toolpath(name: "Pocket\r\nG0 Z-9", kind: .pocket, tool: evil,
                      moves: [.rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.1), feed: 30), .rapid(to: Vec3(1, 1, 0.2))])
    for profile in [BuiltInPosts.avidMach4Inch, BuiltInPosts.genericGRBLMM] {
        let text = try post([tp], profile: profile)
        // Every line is a comment or starts with a G-code word; nothing injected.
        for line in text.split(separator: "\n") {
            let first = line.first!
            #expect(first == "(" || first == ";" || first == "N" || "GMTSF".contains(first), "line: \(line)")
        }
    }
}

@Test func templatePlaceholdersAreSubstitutedInOnePass() {
    let r = TemplateRenderer(values: ["T": "{S}", "S": "18000", "TOOL_NAME": "Bit {S} }{"])
    #expect(r.render("T{T} S{S}") == "T{S} S18000")          // a value is never re-scanned
    #expect(r.render("(Tool: {TOOL_NAME})") == "(Tool: Bit {S} }{)")
    #expect(r.render("G43 H{T} {UNKNOWN} {") == "G43 H{S} {UNKNOWN} {")   // unknown names stay literal
}

// MARK: Numbers

@Test func postRefusesNonFiniteMoves() {
    let tp = Toolpath(name: "bad", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(.nan, 1, -0.1), feed: 30),
    ])
    #expect(throws: PostError.nonFiniteMove(toolpath: "bad")) { try post([tp]) }
    let inf = Toolpath(name: "inf", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .arcCCW(to: Vec3(2, 1, -0.1), center: Vec2(1.5, .infinity), feed: 30),
    ])
    #expect(throws: PostError.nonFiniteMove(toolpath: "inf")) { try post([inf]) }
    #expect(NumberFormat.duration(.infinity) == "unknown")
    #expect(NumberFormat.duration(.nan) == "unknown")
    #expect(ArcGeometry.points(from: Vec3(0, 0, 0), to: Vec3(1, 0, 0), center: Vec2(.nan, 0), clockwise: true,
                               tolerance: 0.001) == [Vec3(1, 0, 0)])
}

@Test func anArcShorterThanTheOutputResolutionIsNotAFullCircle() throws {
    // Both ends round to X1.0000 Y1.0000 at 4 decimals: as G3 the controller would cut a
    // full 1-inch circle at depth. The writer must emit a line (which is then a no-op).
    let tp = Toolpath(name: "tiny", kind: .profile, tool: tool, moves: [
        .rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.1), feed: 30),
        .arcCCW(to: Vec3(1.00001, 1.0000, -0.1), center: Vec2(1, 1.5), feed: 100),
        .arcCCW(to: Vec3(1.00004, 1.0000, -0.1), center: Vec2(1, 1.5), feed: 100),   // rounds onto the start
        .arcCCW(to: Vec3(1, 1, -0.1), center: Vec2(1, 1.5), feed: 100),              // a real full circle
        .rapid(to: Vec3(1, 1, 0.2)),
    ])
    let lines = try post([tp]).split(separator: "\n").map(String.init)
    let arcs = lines.filter { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") }
    #expect(arcs == ["G3 X1.0000 Y1.0000 I0.0000 J0.5000 F100.0"], "\(lines)")
}

// MARK: Validator

@Test func validatorWarnsAboutCoordinateShiftsUnknownWordsAndSpindleState() {
    let base = "G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.2\n"
    #expect(warns(validate(base + "G92 Z0\nG0 Z0.2\nM5\nM30\n"), "G92 changes the coordinate system"))
    #expect(warns(validate(base + "G999\nM99\nM5\nM30\n"), "G999 is not a code"))
    #expect(warns(validate(base + "G999\nM99\nM5\nM30\n"), "M99 is not a code"))
    #expect(warns(validate(base + "T2 M6\nM5\nM30\n"), "Tool change (M6) with the spindle running"))
    #expect(warns(validate(base + "M30\n"), "ends with the spindle running"))
    #expect(warns(validate(base + "M5\nM30\nG0 X0 Y0\n"), "Motion after the program end"))
    #expect(warns(validate("G20\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\nG0 Z0.2\nM5\nM30\n"), "Motion before G90"))
    #expect(warns(validate("G20\nG90\nG0 Z0.2\nM3\nG0 X1 Y1\nM5\nM30\n"), "no speed (S) set"))
    let clean = validate(base + "M5\nM30\n")
    #expect(clean.isEmpty, "\(clean)")
}

/// A block-delete line runs when Block Delete is off (LinuxCNC, Mach), so it is checked like any other line (#120).
@Test func blockDeleteLinesAreChecked() {
    let issues = validate("G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X1 Y1\n/G1 Z-1 F20\nG0 Z0.2\nM5\nM30\n")
    #expect(issues.contains { $0.severity == .error && $0.message.contains("below the allowed depth") }, "\(issues)")
    #expect(issues.contains { $0.severity == .warning && $0.line == 6 && $0.message.contains("Block Delete") })
    #expect(GCodeParser.parse("/G1 Z-1").blocks.first?.value("Z") == -1)
}

/// The file preview draws a block-delete line as if Block Delete were off, and says so (#120).
@Test func previewSaysBlockDeleteLinesAreShown() {
    let r = GCodeReader.read("G20\nG90\nG0 X0 Y0 Z0.2\n/G1 Z-1 F10\n", units: .inch, startZ: 0.2)
    #expect(r.warnings.contains { $0.contains("Line 4") && $0.contains("Block Delete") }, "\(r.warnings)")
}

/// An R arc is checked along its sweep, not only at its end (#120): the long way round from X0 to X10 with R-50 is ~100 in wide.
@Test func rArcsAreCheckedAlongTheirPath() {
    let long = validate("G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X0 Y0\nG1 Z-0.1 F30\nG2 X10 Y0 R-50 F30\nG0 Z0.2\nM5\nM30\n")
    #expect(long.contains { $0.severity == .error && $0.message.contains("travel") }, "\(long)")
    let short = validate("G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X0 Y0\nG1 Z-0.1 F30\nG2 X10 Y0 R50 F30\nG0 Z0.2\nM5\nM30\n")
    #expect(!short.contains { $0.message.contains("travel") }, "\(short)")
    let unreachable = validate("G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X0 Y0\nG1 Z-0.1 F30\nG2 X10 Y0 R1 F30\nG0 Z0.2\nM5\nM30\n")
    #expect(unreachable.contains { $0.severity == .error && $0.message.contains("R arc") })
}

/// Switching units mid-program keeps the travel seen so far (#120): 59 in, then 1000 mm the other way, spans ~98 in.
@Test func aUnitsSwitchKeepsTheTravelSoFar() {
    let issues = validate("G20\nG90\nG0 Z0.2\nM3 S18000\nG0 X0 Y0\nG0 X59 Y0\nG21\nG0 X-1000 Y0\nM5\nM30\n")
    #expect(issues.contains { $0.severity == .error && $0.message.contains("X travel") }, "\(issues)")
}

@Test func twoToolsWithOneNumberAreReported() {
    var other = PostFixtures.vBit          // a different tool (id, geometry)...
    other.number = tool.number             // ...posting as the same T word
    var twin = tool                        // same geometry, different id
    twin.id = UUID()
    func tp(_ t: Tool, _ name: String) -> Toolpath {
        Toolpath(name: name, kind: .profile, tool: t, moves: [.rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.1), feed: 30),
                                                             .rapid(to: Vec3(1, 1, 0.2))])
    }
    let v = GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: PostFixtures.job(), units: .inch)
    let clash = v.validate(toolpaths: [tp(tool, "a"), tp(other, "b")])
    #expect(clash.contains { $0.severity == .error && $0.message.contains("T\(tool.number) is used by 2 different tools") })
    let same = v.validate(toolpaths: [tp(tool, "a"), tp(twin, "b")])
    #expect(same.contains { $0.severity == .warning && $0.message.contains("T\(tool.number)") })
    #expect(v.validate(toolpaths: [tp(tool, "a"), tp(tool, "b")]).isEmpty)
}

// MARK: Reader

@Test func readerSurvivesHugeToolNumbersAndTinyPecks() {
    let r = GCodeReader.read("G20 G90\nT99999999999999999999 M6\nG0 X0 Y0 Z0.2\n", units: .inch, startZ: 0.2)
    #expect(r.segments.last?.toolNumber == nil)
    let pecks = GCodeReader.read("G20 G90\nG0 Z0.2\nG83 X1 Y1 Z-1 R0.1 Q0.0000001 F10\n", units: .inch, startZ: 0.2)
    #expect(pecks.segments.flatMap(\.moves).count < 40_000)
}
