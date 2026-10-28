import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

// Golden programs for `PostFixtures.postJob()` (inch document) in every shipped profile.
// Regenerate deliberately: any diff here changes what reaches the machine.

private func post(_ profile: PostProfile, zZero: ZZeroMode = .materialTop) throws -> String {
    try TemplatePostProcessor(profile: profile).post(PostFixtures.postJob(zZero: zZero))
}

private func expectSameLines(_ actual: String, _ expected: String) {
    #expect(actual.hasSuffix("\n"))
    let a = actual.dropLast().components(separatedBy: "\n"), e = expected.components(separatedBy: "\n")
    for (i, (x, y)) in zip(a, e).enumerated() where x != y {
        Issue.record("line \(i + 1): got '\(x)', expected '\(y)'")
        return
    }
    #expect(a.count == e.count)
}

@Test func goldenAvidMach4Inch() throws {
    expectSameLines(try post(BuiltInPosts.avidMach4Inch), goldenAvidInch)
}

@Test func goldenAvidMach4InchSpoilboardZero() throws {
    expectSameLines(try post(BuiltInPosts.avidMach4Inch, zZero: .spoilboard), goldenAvidInchSpoilboard)
}

@Test func goldenAvidMach4MM() throws {
    expectSameLines(try post(BuiltInPosts.avidMach4MM), goldenAvidMM)
}

@Test func goldenGenericGRBLMM() throws {
    expectSameLines(try post(BuiltInPosts.genericGRBLMM), goldenGRBL)
}

@Test func goldenProgramsPassTheValidator() throws {
    for p in BuiltInPosts.all {
        for mode in [ZZeroMode.materialTop, .spoilboard] {
            let job = PostFixtures.job(zZero: mode)
            // The fixture is a 12 x 8 in job, larger than the Othermill's 5.5 x 4.5 in bed: its posts are checked here on a
            // machine that holds it (as the post editor's sample widens limits), and on their own limits below.
            let checked = othermillIDs.contains(p.id) ? BuiltInMachines.avidPRO6096.applied(to: p) : p
            let issues = GCodeValidator(profile: checked, job: job, units: .inch).validate(gcode: try post(p, zZero: mode))
            #expect(issues.isEmpty, "\(p.id) \(mode): \(issues)")
        }
    }
}

// The posts added after the first three: their dialect lines, as literals (the whole output is pinned by samples/expected).
private struct NewPost: Sendable, CustomStringConvertible {
    let id, unitsCode, zWord: String
    let preamble, toolChange, footerTail: [String]
    var description: String { id }
}

private let grblPreamble = ["G90", "G17", "G94"]
private let linuxCNCPreamble = ["G90", "G91.1", "G17", "G40", "G49", "G80", "G94"]
private let endMillChange = #"Change to Tool: 1/4" End Mill [2 flute]"#

private let othermillIDs: Set<String> = ["othermill-inch", "othermill-mm"]
private let othermillPreamble = ["G90", "G94", "G17", "G55"]
private let bbPreamble = ["G90", "G91.1", "G17", "G49", "G94"]
private let carbidePreamble = ["G90", "G17", "G40", "G49", "G54"]
private let carbideChange = ["M5", "; Change to Tool: 1/4\" End Mill [2 flute]", "T1 M6"]
private let massoPreamble = ["G90", "G17", "G40", "G80", "G94"]
private let uccncPreamble = ["G90", "G17", "G40", "G49", "G80", "G94"]

private let newPosts = [
    NewPost(id: "generic-grbl-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: grblPreamble,
            toolChange: ["M5", "(\(endMillChange))", "M0"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M2"]),
    NewPost(id: "linuxcnc-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: linuxCNCPreamble,
            toolChange: ["M5", "(MSG, \(endMillChange))", "M0"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M2"]),
    NewPost(id: "linuxcnc-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: linuxCNCPreamble,
            toolChange: ["M5", "(MSG, \(endMillChange))", "M0"], footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M2"]),
    NewPost(id: "othermill-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: othermillPreamble,
            toolChange: ["M5", "(\(endMillChange))", "T1 M6"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M30"]),
    NewPost(id: "othermill-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: othermillPreamble,
            toolChange: ["M5", "(\(endMillChange))", "T1 M6"], footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M30"]),
    NewPost(id: "onefinity-bb-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: bbPreamble,
            toolChange: ["M5", "(MSG, \(endMillChange))", "M0"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M2"]),
    NewPost(id: "onefinity-bb-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: bbPreamble,
            toolChange: ["M5", "(MSG, \(endMillChange))", "M0"], footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M2"]),
    NewPost(id: "carbide-motion-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: carbidePreamble,
            toolChange: carbideChange, footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M2"]),
    NewPost(id: "carbide-motion-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: carbidePreamble,
            toolChange: carbideChange, footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M2"]),
    NewPost(id: "masso-g3-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: massoPreamble,
            toolChange: ["M5", "(\(endMillChange))", "T1 M6"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M30"]),
    NewPost(id: "masso-g3-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: massoPreamble,
            toolChange: ["M5", "(\(endMillChange))", "T1 M6"], footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M30"]),
    NewPost(id: "uccnc-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: uccncPreamble,
            toolChange: ["M5", "(\(endMillChange))", "M0"], footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M30"]),
    NewPost(id: "uccnc-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: uccncPreamble,
            toolChange: ["M5", "(\(endMillChange))", "M0"], footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M30"]),
    NewPost(id: "centroid-inch", unitsCode: "G20", zWord: "G0 Z0.2000", preamble: uccncPreamble,
            toolChange: carbideChange, footerTail: ["G0 Z0.8000", "M5", "G0 X0.0000 Y0.0000", "M30"]),
    NewPost(id: "centroid-mm", unitsCode: "G21", zWord: "G0 Z5.080", preamble: uccncPreamble,
            toolChange: carbideChange, footerTail: ["G0 Z20.320", "M5", "G0 X0.000 Y0.000", "M30"]),
]

private func contains(_ lines: [String], run: [String]) -> Bool {
    guard run.count <= lines.count else { return false }
    return (0...(lines.count - run.count)).contains { Array(lines[$0..<($0 + run.count)]) == run }
}

@Test(arguments: newPosts) private func newPostsWriteTheirDialect(_ row: NewPost) throws {
    let profile = try #require(BuiltInPosts.profile(id: row.id))
    let lines = try post(profile).split(separator: "\n").map(String.init)
    let start = try #require(lines.firstIndex(of: row.unitsCode), "no \(row.unitsCode)")
    #expect(Array(lines[(start + 1)...].prefix(row.preamble.count)) == row.preamble)
    #expect(contains(lines, run: row.toolChange), "tool change \(row.toolChange)")
    #expect(Array(lines.suffix(row.footerTail.count)) == row.footerTail)
    #expect(lines.contains(row.zWord), "no \(row.zWord)")
}

private struct PostNumbers: Sendable, CustomStringConvertible {
    let id, name, ext: String
    let units: LengthUnit
    let decimals, feedDecimals: Int
    let x, y, z, spoilboard, rapid, feed, minRPM, maxRPM, arcTolerance: Double
    var description: String { id }
}

private let newPostNumbers = [
    PostNumbers(id: "generic-grbl-inch", name: "Generic GRBL (inch)", ext: "nc", units: .inch, decimals: 4, feedDecimals: 1,
                x: 29.5, y: 29.5, z: 2.55, spoilboard: 0.039, rapid: 314.9, feed: 314.9, minRPM: 0, maxRPM: 30000,
                arcTolerance: 0.0005),
    PostNumbers(id: "linuxcnc-inch", name: "LinuxCNC (inch)", ext: "ngc", units: .inch, decimals: 4, feedDecimals: 1,
                x: 48, y: 48, z: 6, spoilboard: 0.05, rapid: 200, feed: 200, minRPM: 0, maxRPM: 24000, arcTolerance: 0.0005),
    PostNumbers(id: "linuxcnc-mm", name: "LinuxCNC (mm)", ext: "ngc", units: .millimeter, decimals: 3, feedDecimals: 0,
                x: 1219.2, y: 1219.2, z: 152.4, spoilboard: 1.27, rapid: 5080, feed: 5080, minRPM: 0, maxRPM: 24000,
                arcTolerance: 0.01),
    PostNumbers(id: "othermill-inch", name: "Othermill (inch)", ext: "gcode", units: .inch, decimals: 4, feedDecimals: 1,
                x: 5.5, y: 4.5, z: 1.35, spoilboard: 0.01, rapid: 100, feed: 100, minRPM: 7000, maxRPM: 26000,
                arcTolerance: 0.0005),
    PostNumbers(id: "othermill-mm", name: "Othermill (mm)", ext: "gcode", units: .millimeter, decimals: 3, feedDecimals: 0,
                x: 139.7, y: 114.3, z: 34.29, spoilboard: 0.254, rapid: 2540, feed: 2540, minRPM: 7000, maxRPM: 26000,
                arcTolerance: 0.01),
    PostNumbers(id: "onefinity-bb-inch", name: "Onefinity Buildbotics (inch)", ext: "ngc", units: .inch, decimals: 4,
                feedDecimals: 1, x: 32.125, y: 32.125, z: 5.25, spoilboard: 0.05, rapid: 400, feed: 400, minRPM: 10000,
                maxRPM: 30000, arcTolerance: 0.0005),
    PostNumbers(id: "onefinity-bb-mm", name: "Onefinity Buildbotics (mm)", ext: "ngc", units: .millimeter, decimals: 3,
                feedDecimals: 0, x: 815.975, y: 815.975, z: 133.35, spoilboard: 1.27, rapid: 10160, feed: 10160, minRPM: 10000,
                maxRPM: 30000, arcTolerance: 0.01),
    PostNumbers(id: "carbide-motion-inch", name: "Carbide Motion (inch)", ext: "nc", units: .inch, decimals: 4, feedDecimals: 1,
                x: 24.5, y: 24.5, z: 6.1, spoilboard: 0.039, rapid: 314.9, feed: 314.9, minRPM: 0, maxRPM: 30000,
                arcTolerance: 0.0005),
    PostNumbers(id: "carbide-motion-mm", name: "Carbide Motion (mm)", ext: "nc", units: .millimeter, decimals: 3, feedDecimals: 0,
                x: 623, y: 623, z: 155, spoilboard: 1.0, rapid: 8000, feed: 8000, minRPM: 0, maxRPM: 30000, arcTolerance: 0.01),
] + genericController("masso-g3", "MASSO G3", mmFeedDecimals: 1) + genericController("uccnc", "UCCNC", mmFeedDecimals: 0)
  + genericController("centroid", "Centroid CNC12", mmFeedDecimals: 0)

/// MASSO, UCCNC and Centroid run on many machines: the posts carry the LinuxCNC posts' generic envelope, which a machine replaces.
private func genericController(_ id: String, _ name: String, mmFeedDecimals: Int) -> [PostNumbers] {
    [PostNumbers(id: "\(id)-inch", name: "\(name) (inch)", ext: "nc", units: .inch, decimals: 4, feedDecimals: 1, x: 48, y: 48,
                 z: 6, spoilboard: 0.05, rapid: 200, feed: 200, minRPM: 0, maxRPM: 24000, arcTolerance: 0.0005),
     PostNumbers(id: "\(id)-mm", name: "\(name) (mm)", ext: "nc", units: .millimeter, decimals: 3, feedDecimals: mmFeedDecimals,
                 x: 1219.2, y: 1219.2, z: 152.4, spoilboard: 1.27, rapid: 5080, feed: 5080, minRPM: 0, maxRPM: 24000,
                 arcTolerance: 0.01)]
}

/// Codes each controller must never receive (#107, #108, #103), on parsed words (`G20` is not `G2`), in both Z-zero modes, on
/// a job with an arc, an optional-stop pause, the spin-up dwell and a tool name with parentheses.
@Test(arguments: ["masso-g3-inch", "masso-g3-mm", "uccnc-inch", "uccnc-mm", "centroid-inch", "centroid-mm"])
func massoUCCNCCentroidWriteOnlyTheirCodes(_ id: String) throws {
    let p = try #require(BuiltInPosts.profile(id: id))
    let forbidden: [(Character, Double)]
    switch id {
    case _ where id.hasPrefix("masso"): forbidden = [("G", 91.1), ("G", 49), ("G", 43), ("M", 1)]
    case _ where id.hasPrefix("uccnc"): forbidden = [("G", 91.1), ("M", 6), ("G", 2), ("G", 3), ("M", 1)]
    default: forbidden = [("G", 91.1), ("G", 2), ("G", 3), ("M", 1)]
    }
    for mode in [ZZeroMode.materialTop, .spoilboard] {
        var job = PostFixtures.postJob(zZero: mode)
        job.toolpaths[0].pauseAfter = PauseStep(message: "Flip (side)", isOptionalStop: true)
        let text = try TemplatePostProcessor(profile: p).post(job)
        let blocks = GCodeParser.parse(text).blocks
        for (letter, value) in forbidden {
            #expect(!blocks.contains { $0.has(letter, value) }, "\(id) \(mode) writes \(letter)\(value)")
        }
        #expect(blocks.contains { $0.has("M", 0) }, "\(id): the optional stop writes M0")
        let dwell = id.hasPrefix("centroid") ? "\nG4 P3\n" : "\nG4 P3000\n"
        #expect(text.contains(dwell), "\(id) \(mode)")
        if id.hasPrefix("uccnc") { #expect(!blocks.contains { $0.value("T") != nil }, "\(id) writes a T word") }
        if id.hasPrefix("centroid") {
            #expect(!text.contains("("), "\(id) writes a parenthesis")
            #expect(!blocks.contains { $0.values("M").count > 1 }, "\(id) writes two M words on a line")
        }
        if id.hasPrefix("masso") {
            let preamble = text.split(separator: "\n").drop { !$0.hasPrefix("G2") }.dropFirst().prefix(5)
            #expect(preamble.allSatisfy { !$0.contains(" ") }, "\(id): one word per preamble line")
        }
    }
}

/// What each new controller must never receive (#104, #105), in both Z-zero modes; Carbide Motion has no `(` at all.
@Test(arguments: ["onefinity-bb-inch", "onefinity-bb-mm", "carbide-motion-inch", "carbide-motion-mm"])
func bbAndCarbideWriteOnlyTheirCodes(_ id: String) throws {
    let p = try #require(BuiltInPosts.profile(id: id))
    let forbidden: [(Character, Double)] = id.hasPrefix("onefinity")
        ? [("G", 40), ("G", 80), ("M", 30), ("M", 1)]
        : [("G", 94), ("G", 80), ("G", 91.1), ("M", 30), ("M", 1)]
    for mode in [ZZeroMode.materialTop, .spoilboard] {
        let text = try post(p, zZero: mode)
        let blocks = GCodeParser.parse(text).blocks
        for (letter, value) in forbidden {
            #expect(!blocks.contains { $0.has(letter, value) }, "\(id) \(mode) writes \(letter)\(value)")
        }
        #expect(text.contains("\nG4 P3\n"), "\(id) \(mode)")
        if id.hasPrefix("carbide") { #expect(!text.contains("("), "\(id) \(mode) writes a parenthesis") }
    }
}

/// Codes the Othermill's software does not run (spec #114, facts 4, 6, 8 and the coolant row): a skipped line is silent there.
@Test(arguments: ["othermill-inch", "othermill-mm"]) func othermillWritesNoForbiddenCode(_ id: String) throws {
    let p = try #require(BuiltInPosts.profile(id: id))
    let text = try post(p)
    let blocks = GCodeParser.parse(text).blocks
    let forbidden: [(Character, Double)] = [("G", 40), ("G", 49), ("G", 91.1), ("G", 43), ("G", 53), ("G", 28),
                                            ("M", 7), ("M", 8), ("M", 9), ("M", 4)]
    for (letter, value) in forbidden {
        #expect(!blocks.contains { $0.has(letter, value) }, "\(id) writes \(letter)\(value)")
    }
    #expect(text.contains("\nG4 P4\n"))
}

@Test(arguments: ["othermill-inch", "othermill-mm"]) func othermillLinearisesHelices(_ id: String) throws {
    let p = try #require(BuiltInPosts.profile(id: id))
    let mc = MachineCoordinates(job: PostFixtures.job(zZero: .materialTop))
    let tp = Toolpath(name: "Helix", kind: .profile, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(2, 1, mc.safeZ)),
        .linear(to: Vec3(2, 1, 0), feed: 30),
        .arcCW(to: Vec3(2, 3, -0.1), center: Vec2(2, 2), feed: 60),
        .rapid(to: Vec3(2, 3, mc.safeZ)),
    ])
    let job = PostJob(name: "H", units: .inch, job: PostFixtures.job(zZero: .materialTop), toolpaths: [tp])
    let blocks = GCodeParser.parse(try TemplatePostProcessor(profile: p).post(job)).blocks
    #expect(!blocks.contains { $0.has("G", 2) || $0.has("G", 3) })
}

/// Every arc LoftLine writes comes from `ArcFitter`, whose sweep is at most 180°, the Othermill post's own limit.
@Test(arguments: ["othermill-inch", "othermill-mm"]) func othermillSampleArcsSweepAtMost180(_ id: String) throws {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("samples/expected/\(id)")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    #expect(!files.isEmpty)
    var arcs = 0
    for file in files {
        var at = Vec2(0, 0)
        for b in GCodeParser.parse(try String(contentsOf: file, encoding: .utf8)).blocks {
            let end = Vec2(b.value("X") ?? at.x, b.value("Y") ?? at.y)
            if b.has("G", 2) || b.has("G", 3), let i = b.value("I"), let j = b.value("J") {
                let sweep = ArcGeometry.sweep(from: at, to: end, center: Vec2(at.x + i, at.y + j), clockwise: b.has("G", 2))
                #expect(abs(sweep) <= .pi + 1e-6, "\(file.lastPathComponent): sweep \(sweep)")
                arcs += 1
            }
            at = end
        }
    }
    #expect(arcs > 0)
}

/// The Othermill posts on their own limits: a job that fits the Pro's 5.5 x 4.5 x 1.35 in posts with no issue.
@Test(arguments: ["othermill-inch", "othermill-mm"]) func othermillOwnLimitsPassTheValidator(_ id: String) throws {
    let p = try #require(BuiltInPosts.profile(id: id))
    var job = JobSetup(width: 4, height: 3, thickness: 0.25, safeZ: 0.2, homeZ: 0.5)
    job.material = "MDF"
    let mc = MachineCoordinates(job: job)
    let d = mc.z(depth: 0.1)
    let tp = Toolpath(name: "Small", kind: .profile, tool: PostFixtures.endMill, moves: [
        .rapid(to: Vec3(1, 1, mc.safeZ)),
        .linear(to: Vec3(1, 1, d), feed: 30),
        .linear(to: Vec3(3, 1, d), feed: 60),
        .linear(to: Vec3(3, 2, d), feed: 60),
        .rapid(to: Vec3(3, 2, mc.safeZ)),
    ])
    let text = try TemplatePostProcessor(profile: p).post(PostJob(name: "S", units: .inch, job: job, toolpaths: [tp]))
    let issues = GCodeValidator(profile: p, job: job, units: .inch).validate(gcode: text)
    #expect(issues.isEmpty, "\(id): \(issues)")
}

private struct MachineNumbers: Sendable, CustomStringConvertible {
    let id, name: String
    let units: LengthUnit
    let x, y, z, spoilboard: Double
    let rapid, feed, minRPM, maxRPM: Double?
    let posts: [String]
    var description: String { id }
}

private let newMachines = [
    MachineNumbers(id: "genmitsu-3018-prover-v2", name: "Genmitsu 3018-PROVer V2", units: .millimeter, x: 290, y: 180, z: 40,
                   spoilboard: 1.0, rapid: nil, feed: nil, minRPM: nil, maxRPM: nil, posts: ["generic-grbl-mm"]),
    MachineNumbers(id: "longmill-mk2-30x30", name: "Sienci LongMill MK2 30x30", units: .millimeter, x: 820, y: 868, z: 114,
                   spoilboard: 1.0, rapid: 4000, feed: 4000, minRPM: nil, maxRPM: nil, posts: ["generic-grbl-mm"]),
    MachineNumbers(id: "onefinity-woodworker", name: "Onefinity Woodworker (Buildbotics)", units: .inch, x: 32.125, y: 32.125,
                   z: 5.25, spoilboard: 0.05, rapid: 400, feed: 400, minRPM: 10000, maxRPM: 30000,
                   posts: ["onefinity-bb-inch", "onefinity-bb-mm"]),
    MachineNumbers(id: "shapeoko-5-pro-2x2", name: "Shapeoko 5 Pro 2x2 (Carbide Motion)", units: .millimeter, x: 623, y: 623,
                   z: 155, spoilboard: 1.0, rapid: nil, feed: nil, minRPM: nil, maxRPM: nil,
                   posts: ["carbide-motion-inch", "carbide-motion-mm"]),
]

@Test(arguments: newMachines) private func newMachinesCarryTheirNumbers(_ n: MachineNumbers) throws {
    let m = try #require(BuiltInMachines.machine(id: n.id))
    #expect(m.name == n.name && m.units == n.units && m.postIDs == n.posts)
    #expect(m.limits == MachineLimits(xTravel: n.x, yTravel: n.y, zTravel: n.z, maxSpoilboardCut: n.spoilboard))
    #expect(m.rapidRate == n.rapid && m.maxFeed == n.feed && m.minRPM == n.minRPM && m.maxRPM == n.maxRPM)
    // Appended after the existing machines, so no existing project infers a new one first.
    let ids = BuiltInMachines.all.map(\.id)
    #expect(try #require(ids.firstIndex(of: n.id)) > #require(ids.firstIndex(of: "othermill")))
}

/// A changed built-in machine would make every saved project's copy "differ": the generic GRBL router keeps its bytes.
@Test func theGenericGRBLMachineIsUnchanged() {
    let m = BuiltInMachines.genericGRBL
    #expect(m.postIDs == ["generic-grbl-mm"] && m.limits == BuiltInPosts.genericGRBLMM.limits)
}

/// None of the new posts declares a controller, so park-and-probe refuses them.
@Test func parkAndProbeRefusesTheNewPosts() {
    for (machine, post) in [(BuiltInMachines.machine(id: "onefinity-woodworker"), BuiltInPosts.onefinityBBInch),
                            (BuiltInMachines.machine(id: "shapeoko-5-pro-2x2"), BuiltInPosts.carbideMotionMM)] {
        guard var m = machine else { Issue.record("missing machine"); continue }
        m.toolChangeProbe = ToolChangeProbe.defaults(for: m)
        guard case .refused? = m.applied(to: post).toolChangeProbe else { Issue.record("\(post.id) probed"); continue }
    }
}

@Test func othermillMachines() throws {
    let pro = try #require(BuiltInMachines.machine(id: "othermill-pro"))
    let original = try #require(BuiltInMachines.machine(id: "othermill"))
    #expect(pro.units == .inch && pro.limits == MachineLimits(xTravel: 5.5, yTravel: 4.5, zTravel: 1.35, maxSpoilboardCut: 0.01))
    #expect(pro.minRPM == 8500 && pro.maxRPM == 26000 && pro.rapidRate == 100 && pro.maxFeed == 100)
    #expect(original.limits == MachineLimits(xTravel: 5.5, yTravel: 4.5, zTravel: 1.25, maxSpoilboardCut: 0.01))
    #expect(original.minRPM == 7000 && original.maxRPM == 16500 && original.rapidRate == 60 && original.maxFeed == 60)
    for m in [pro, original] { #expect(m.postIDs == ["othermill-inch", "othermill-mm"]) }
    let ids = BuiltInMachines.all.map(\.id)
    #expect(try #require(ids.firstIndex(of: "othermill-pro")) < #require(ids.firstIndex(of: "othermill")))
}

@Test(arguments: newPostNumbers) private func newPostsCarryTheirNumbers(_ n: PostNumbers) throws {
    let p = try #require(BuiltInPosts.profile(id: n.id))
    #expect(p.name == n.name && p.fileExtension == n.ext && p.units == n.units)
    #expect(p.decimals == n.decimals && p.feedDecimals == n.feedDecimals)
    #expect(p.limits == MachineLimits(xTravel: n.x, yTravel: n.y, zTravel: n.z, maxSpoilboardCut: n.spoilboard))
    #expect(p.rapidRate == n.rapid && p.maxFeed == n.feed && p.minRPM == n.minRPM && p.maxRPM == n.maxRPM)
    #expect(p.arcTolerance == n.arcTolerance)
}

private let goldenAvidInch = #"""
( Job: Golden )
( Post: Avid PRO6096 Mach4 [inch] v1.0 )
( Units: inches )
( Material: 12.0000 x 8.0000 x 0.7500 in - MDF )
( Z zero: material top [bottom at Z-0.7500] )
( XY origin: lower left )
( Safe Z: 0.2000  Home: X0.0000 Y0.0000 Z0.8000 )
( Tools: )
(   T1: 1/4" End Mill [2 flute] - End Mill, dia 0.2500 in )
(   T6: 60 deg V-Bit 1/2" - V-Bit, dia 0.5000 in )
( Toolpaths: )
(   Profile 1 [Profile, T1, S18000] )
(   V-Carve 1 [V-Carve, T6, S18000] )
( Estimated time: 0m 14s )
G20
G90
G91.1
G17
G40
G49
G80
G94
M5
(Change to Tool: 1/4" End Mill [2 flute])
T1 M6
G0 Z0.2000
M3 S18000
G4 P3
( Toolpath: Profile 1 [Profile] )
G0 X1.0000 Y1.0000
G1 Z-0.2500 F30.0
X3.0000 F100.0
G3 X3.0000 Y3.0000 I0.0000 J1.0000
G1 X1.0000
Y1.0000
G0 Z0.2000
M5
(Change to Tool: 60 deg V-Bit 1/2")
T6 M6
G0 Z0.2000
M3 S18000
G4 P3
( Toolpath: V-Carve 1 [V-Carve] )
G0 X5.0000 Y5.0000
G1 Z-0.1000 F30.0
X6.0000 F80.0
G0 Z0.2000
G0 Z0.8000
M5
G0 X0.0000 Y0.0000
M30
"""#

private let goldenAvidInchSpoilboard = #"""
( Job: Golden )
( Post: Avid PRO6096 Mach4 [inch] v1.0 )
( Units: inches )
( Material: 12.0000 x 8.0000 x 0.7500 in - MDF )
( Z zero: spoilboard surface [top at Z0.7500] )
( XY origin: lower left )
( Safe Z: 0.9500  Home: X0.0000 Y0.0000 Z1.5500 )
( Tools: )
(   T1: 1/4" End Mill [2 flute] - End Mill, dia 0.2500 in )
(   T6: 60 deg V-Bit 1/2" - V-Bit, dia 0.5000 in )
( Toolpaths: )
(   Profile 1 [Profile, T1, S18000] )
(   V-Carve 1 [V-Carve, T6, S18000] )
( Estimated time: 0m 14s )
G20
G90
G91.1
G17
G40
G49
G80
G94
M5
(Change to Tool: 1/4" End Mill [2 flute])
T1 M6
G0 Z0.9500
M3 S18000
G4 P3
( Toolpath: Profile 1 [Profile] )
G0 X1.0000 Y1.0000
G1 Z0.5000 F30.0
X3.0000 F100.0
G3 X3.0000 Y3.0000 I0.0000 J1.0000
G1 X1.0000
Y1.0000
G0 Z0.9500
M5
(Change to Tool: 60 deg V-Bit 1/2")
T6 M6
G0 Z0.9500
M3 S18000
G4 P3
( Toolpath: V-Carve 1 [V-Carve] )
G0 X5.0000 Y5.0000
G1 Z0.6500 F30.0
X6.0000 F80.0
G0 Z0.9500
G0 Z1.5500
M5
G0 X0.0000 Y0.0000
M30
"""#

private let goldenAvidMM = #"""
( Job: Golden )
( Post: Avid PRO6096 Mach4 [mm] v1.0 )
( Units: millimetres )
( Material: 304.800 x 203.200 x 19.050 mm - MDF )
( Z zero: material top [bottom at Z-19.050] )
( XY origin: lower left )
( Safe Z: 5.080  Home: X0.000 Y0.000 Z20.320 )
( Tools: )
(   T1: 1/4" End Mill [2 flute] - End Mill, dia 6.350 mm )
(   T6: 60 deg V-Bit 1/2" - V-Bit, dia 12.700 mm )
( Toolpaths: )
(   Profile 1 [Profile, T1, S18000] )
(   V-Carve 1 [V-Carve, T6, S18000] )
( Estimated time: 0m 14s )
G21
G90
G91.1
G17
G40
G49
G80
G94
M5
(Change to Tool: 1/4" End Mill [2 flute])
T1 M6
G0 Z5.080
M3 S18000
G4 P3
( Toolpath: Profile 1 [Profile] )
G0 X25.400 Y25.400
G1 Z-6.350 F762
X76.200 F2540
G3 X76.200 Y76.200 I0.000 J25.400
G1 X25.400
Y25.400
G0 Z5.080
M5
(Change to Tool: 60 deg V-Bit 1/2")
T6 M6
G0 Z5.080
M3 S18000
G4 P3
( Toolpath: V-Carve 1 [V-Carve] )
G0 X127.000 Y127.000
G1 Z-2.540 F762
X152.400 F2032
G0 Z5.080
G0 Z20.320
M5
G0 X0.000 Y0.000
M30
"""#

private let goldenGRBL = #"""
( Job: Golden )
( Post: Generic GRBL [mm] v1.0 )
( Units: millimetres )
( Material: 304.800 x 203.200 x 19.050 mm - MDF )
( Z zero: material top [bottom at Z-19.050] )
( XY origin: lower left )
( Safe Z: 5.080  Home: X0.000 Y0.000 Z20.320 )
( Tools: )
(   T1: 1/4" End Mill [2 flute] - End Mill, dia 6.350 mm )
(   T6: 60 deg V-Bit 1/2" - V-Bit, dia 12.700 mm )
( Toolpaths: )
(   Profile 1 [Profile, T1, S18000] )
(   V-Carve 1 [V-Carve, T6, S18000] )
( Estimated time: 0m 15s )
G21
G90
G17
G94
M5
(Change to Tool: 1/4" End Mill [2 flute])
M0
G0 Z5.080
M3 S18000
G4 P3
( Toolpath: Profile 1 [Profile] )
G0 X25.400 Y25.400
G1 Z-6.350 F762
X76.200 F2540
G3 X76.200 Y76.200 I0.000 J25.400
G1 X25.400
Y25.400
G0 Z5.080
M5
(Change to Tool: 60 deg V-Bit 1/2")
M0
G0 Z5.080
M3 S18000
G4 P3
( Toolpath: V-Carve 1 [V-Carve] )
G0 X127.000 Y127.000
G1 Z-2.540 F762
X152.400 F2032
G0 Z5.080
G0 Z20.320
M5
G0 X0.000 Y0.000
M2
"""#
