import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The travel checks on every post (#119): the program's zero and its moves fit one travel-sized window, and the stock plus
/// the highest Z fits the Z travel. Each XY program names X and Y in its first motion, so nothing is visited at X0 Y0 by
/// accident (the first Z-only rapid of a posted program is).
@Suite struct TravelWindowTests {
    typealias B = ProbeSequenceBuilderTests

    static func post(_ base: PostProfile = BuiltInPosts.avidMach4Inch, x: Double = 5.5, y: Double = 4.5, z: Double = 8) -> PostProfile {
        var p = base
        p.limits = MachineLimits(xTravel: x, yTravel: y, zTravel: z, maxSpoilboardCut: base.units == .inch ? 0.05 : 1.27)
        return p
    }

    static func mmJob(zZero: ZZeroMode = .materialTop) -> JobSetup {
        JobSetup(width: 300, height: 200, thickness: 18, xyOrigin: .lowerLeft, zZero: zZero, safeZ: 5, homeZ: 20)
    }

    func issues(_ body: String, profile: PostProfile = post(), job: JobSetup = PostFixtures.job(), units: LengthUnit = .inch)
        -> [GCodeIssue] {
        let header = units == .inch ? "G20" : "G21"
        return GCodeValidator(profile: profile, job: job, units: units)
            .validate(gcode: "\(header)\nG90\nM3 S18000\n\(body)\nM5\nM30\n")
    }

    func travel(_ issues: [GCodeIssue], _ axis: String = "X") -> [String] {
        issues.filter { $0.severity == .error && $0.message.hasPrefix("\(axis) travel") }.map(\.message)
    }

    func envelope(_ issues: [GCodeIssue]) -> [String] {
        issues.filter { $0.severity == .warning && $0.message.hasPrefix(GCodeValidator.zEnvelopePrefix) }.map(\.message)
    }

    /// A cut along X at depth 0.1 from `from` to `to`, entered and left at Safe Z.
    func cut(_ from: Double, _ to: Double, y: Double = 1) -> String {
        "G0 X\(from) Y\(y) Z0.2\nG1 Z-0.1 F30\nG1 X\(to) F100\nG0 Z0.2"
    }

    // MARK: XY

    @Test func aShortCutFarFromTheZeroIsAnError() {
        #expect(travel(issues(cut(5.8, 6))) == ["X travel 6.0000 in exceeds the machine's X travel 5.5000 in (the program's "
                                                + "zero and its moves span X0.0000 to X6.0000)"])
    }

    @Test func theEdgeIsInsideInBothUnits() {
        #expect(travel(issues(cut(5, 5.5))).isEmpty)
        #expect(travel(issues(cut(5, 5.50025))).isEmpty)
        #expect(travel(issues(cut(5, 5.501))).count == 1)
        let mm = Self.post(BuiltInPosts.avidMach4MM, x: 139.7, y: 114.3, z: 200)
        func mmCut(_ to: Double) -> String { "G0 X130 Y10 Z5\nG1 Z-2 F500\nG1 X\(to) F1000\nG0 Z5" }
        #expect(travel(issues(mmCut(139.7), profile: mm, job: Self.mmJob(), units: .millimeter)).isEmpty)
        #expect(travel(issues(mmCut(139.705), profile: mm, job: Self.mmJob(), units: .millimeter)).isEmpty)
        #expect(travel(issues(mmCut(139.72), profile: mm, job: Self.mmJob(), units: .millimeter)).count == 1)
    }

    @Test func eachOriginsMovesFitOrNot() {
        #expect(travel(issues(cut(-3, 3))).count == 1, "centre: window 6")
        #expect(travel(issues(cut(-5, -0.5, y: -1))).isEmpty, "upper right: window 5")
        #expect(travel(issues(cut(-5, -0.5, y: 4) + "\nG0 X0 Y0 Z0.8")).isEmpty && travel(issues(cut(-5, -0.5, y: 4)), "Y").isEmpty,
                "lower right")
        #expect(travel(issues(cut(0.5, 5, y: -4) + "\nG0 X0 Y0 Z0.8")).isEmpty && travel(issues(cut(0.5, 5, y: -4)), "Y").isEmpty,
                "upper left")
    }

    @Test func aDatumOffsetMovesTheWindow() {
        #expect(travel(issues(cut(-2, 3))).isEmpty)
        #expect(travel(issues(cut(-2, 4))).count == 1)
    }

    @Test func aMoveHomePastTheBedIsAnError() {
        #expect(travel(issues(cut(1, 2) + "\nG0 Z0.8\nG0 X6 Y1")).count == 1)
    }

    @Test func noMovesNoTravelError() {
        #expect(travel(issues("")).isEmpty && envelope(issues("")).isEmpty)
    }

    @Test func theToolpathPassLeavesTravelToTheProgram() {
        let mc = MachineCoordinates(job: PostFixtures.job())
        let tp = Toolpath(name: "Wide", kind: .profile, tool: PostFixtures.endMill, moves: [
            .rapid(to: Vec3(0, 1, mc.safeZ)), .linear(to: Vec3(0, 1, -0.1), feed: 30), .linear(to: Vec3(6, 1, -0.1), feed: 100),
        ])
        let found = GCodeValidator(profile: Self.post(), job: PostFixtures.job(), units: .inch).validate(toolpaths: [tp])
        #expect(!found.contains { $0.message.contains("travel") }, "\(found)")
    }

    @Test func aUnitsSwitchKeepsTheZeroInTheWindow() {
        let body = cut(4, 5) + "\nG21\nG0 X140 Y25.4 Z5\nG1 Z-2 F500\nG1 X150 F1000\nG0 Z5"
        #expect(issues(body).contains { $0.severity == .error && $0.message.hasPrefix("X travel") }, "\(issues(body))")
    }

    func probed(spot: Vec2, limits: (Double, Double, Double), homeZ: Double = 0.8) throws -> [GCodeIssue] {
        var probe = B.mach4
        probe.parkZ = -0.3
        var p = B.profile(BuiltInPosts.avidMach4Inch, probe: probe)
        p.limits = MachineLimits(xTravel: limits.0, yTravel: limits.1, zTravel: limits.2, maxSpoilboardCut: 0.05)
        var job = B.job(spot: spot)
        job.homeZ = homeZ
        let tps = [B.cut("A", job: job), B.cut("B", tool: PostFixtures.vBit, at: 3, job: job)]
        let text = try TemplatePostProcessor(profile: p).post(PostJob(name: "P", units: .inch, job: job, toolpaths: tps))
        return GCodeValidator(profile: p, job: job, units: .inch).validate(gcode: text)
    }

    @Test func theTouchOffSpotCountsInTheWindow() throws {
        #expect(travel(try probed(spot: Vec2(5, 4), limits: (5.5, 8, 8))).isEmpty)
        #expect(travel(try probed(spot: Vec2(6, 4), limits: (5.5, 8, 8))).count == 1)
    }

    // MARK: Z

    @Test(arguments: [ZZeroMode.materialTop, .spoilboard]) func theStockPlusHomeZWarns(_ zZero: ZZeroMode) {
        let lift = zZero == .spoilboard ? 0.75 : 0
        func z(_ v: Double) -> String { NumberFormat.compact(v + lift, maxDecimals: 4) }
        let body = "G0 X1 Y1 Z\(z(0.2))\nG1 Z\(z(-0.1)) F30\nG1 X2 F100\nG0 Z\(z(0.8))"
        let found = envelope(issues(body, profile: Self.post(z: 1.35), job: PostFixtures.job(zZero: zZero)))
        #expect(found.count == 1 && found[0].contains("1.5500 in"), "\(found)")
        #expect(envelope(issues(body, profile: Self.post(z: 1.55), job: PostFixtures.job(zZero: zZero))).isEmpty)
    }

    @Test func exactlyTheZTravelIsCleanInMillimeters() {
        let body = "G0 X10 Y10 Z5\nG1 Z-2 F500\nG1 X20 F1000\nG0 Z20"
        let mm = Self.post(BuiltInPosts.avidMach4MM, x: 500, y: 500, z: 38)
        #expect(envelope(issues(body, profile: mm, job: Self.mmJob(), units: .millimeter)).isEmpty)
        let tight = Self.post(BuiltInPosts.avidMach4MM, x: 500, y: 500, z: 37.9)
        #expect(envelope(issues(body, profile: tight, job: Self.mmJob(), units: .millimeter)).count == 1)
    }

    @Test func aZSpanErrorIsNotAlsoWarned() {
        let body = "G0 X1 Y1 Z0.55\nG1 Z-0.8 F30\nG1 X2 F100\nG0 Z0.55"
        let found = issues(body, profile: Self.post(z: 1.33))
        #expect(found.contains { $0.severity == .error && $0.message.hasPrefix("Z travel") })
        #expect(envelope(found).isEmpty)
    }

    @Test func thePlateClearanceCountsInTheZWarning() throws {
        // Home Z 0.3, Safe Z 0.2: the highest Z is the clearance over the 0.5 in plate, 0.7.
        let found = envelope(try probed(spot: Vec2(6, 4), limits: (12, 8, 1.4), homeZ: 0.3))
        #expect(found.count == 1 && found[0].contains("Z0.7000"), "\(found)")
    }

    // MARK: The Othermill (#114's checks, now the general ones)

    @Test func aMoveOrAHomeBeyondTheOthermillBedIsAnError() {
        let om = BuiltInPosts.othermillInch
        #expect(travel(issues(cut(5.8, 6), profile: om)).count == 1)
        #expect(travel(issues(cut(1, 3) + "\nG0 Z0.5\nG0 X6 Y0", profile: om)).count == 1)
        #expect(travel(issues(cut(1, 2, y: 4.6), profile: om), "Y").count == 1)
    }

    @Test func theOthermillBedEdgeIsInsideInEitherUnit() {
        let edge = "G0 X0 Y0 Z0.2\nG1 Z-0.1 F30\nG1 X5.5 Y4.5 F100\nG0 Z0.2"
        let inch = issues(edge, profile: BuiltInPosts.othermillMM)
        #expect(travel(inch).isEmpty && travel(inch, "Y").isEmpty, "\(inch)")
        let mmEdge = "G0 X0 Y0 Z5\nG1 Z-2 F500\nG1 X139.7 Y114.3 F1000\nG0 Z5"
        let mm = issues(mmEdge, profile: BuiltInPosts.othermillInch, job: Self.mmJob(), units: .millimeter)
        #expect(travel(mm).isEmpty && travel(mm, "Y").isEmpty, "\(mm)")
    }

    @Test func theStockPlusTheHighestZMustFitTheOthermillsZTravel() {
        let om = BuiltInPosts.othermillInch
        func warns(thickness: Double, highest: Double) -> Bool {
            var j = PostFixtures.job()
            j.thickness = thickness
            return !envelope(issues("G0 X1 Y1 Z0.2\nG1 Z-0.05 F30\nG0 Z\(highest)", profile: om, job: j)).isEmpty
        }
        #expect(warns(thickness: 0.75, highest: 0.8))    // 0.75 + 0.8 = 1.55 > 1.35
        #expect(!warns(thickness: 0.75, highest: 0.6))   // 1.35, the boundary
        #expect(warns(thickness: 0.75, highest: 0.7))    // a clamp raises the approach: 1.45
        #expect(!warns(thickness: 0.25, highest: 0.5))
    }

    // MARK: Coordinate shifts

    @Test func aCoordinateShiftSaysTravelChecksNoLongerApply() {
        let found = issues("G0 X0 Y0 Z0.2\nG0 X5\nG92 X0\nG0 X5")
        #expect(found.contains { $0.severity == .warning && $0.message.contains("depth and travel checks no longer apply") })
    }
}
