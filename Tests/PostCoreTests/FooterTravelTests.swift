import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The footer's travel, walked from its rendered moves (#132).
@Suite struct FooterTravelTests {
    static func job(_ zZero: ZZeroMode = .materialTop, homeZ: Double = 0.8) -> JobSetup {
        JobSetup(width: 12, height: 8, thickness: 0.75, xyOrigin: .lowerLeft, zZero: zZero, safeZ: 0.2, homeZ: homeZ,
                 home: Vec2(0, 0))
    }

    static func walk(_ footer: [String]? = nil, profile: PostProfile = BuiltInPosts.avidMach4Inch, job: JobSetup = job(),
                     end: Vec3? = nil, toolpaths: [Toolpath] = [], approach: Double? = nil) -> FooterTravel {
        var p = profile
        if let footer { p.footer = footer }
        let mc = MachineCoordinates(job: job)
        let post = PostJob(name: "T", units: .inch, job: job, toolpaths: toolpaths, approachHeight: approach)
        return FooterTravel.model(profile: p, job: post, from: end ?? Vec3(5, 1, mc.z(depth: 0.25)))
    }

    static func close(_ a: [Vec3], _ b: [Vec3], _ tol: Double = 1e-3) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.distance(to: $1) <= tol }
    }

    @Test(arguments: [ZZeroMode.materialTop, .spoilboard])
    func everyBuiltInPostGoesUpThenHome(mode: ZZeroMode) {
        let mc = MachineCoordinates(job: Self.job(mode))
        let want = [Vec3(5, 1, mc.safeZ), Vec3(5, 1, mc.homeZ), Vec3(0, 0, mc.homeZ)]
        for profile in BuiltInPosts.all {
            let t = Self.walk(profile: profile, job: Self.job(mode))
            #expect(Self.close(t.points, want), "\(profile.id): \(t.points)")
            #expect(t.unmodelledFrom == nil, "\(profile.id)")
        }
    }

    @Test func homeZAtSafeZDropsTheZMove() {
        let mc = MachineCoordinates(job: Self.job(homeZ: 0.2))
        let t = Self.walk(job: Self.job(homeZ: 0.2))
        #expect(Self.close(t.points, [Vec3(5, 1, mc.safeZ), Vec3(0, 0, mc.safeZ)]), "\(t.points)")
    }

    @Test func aG28BeforeHomeZCrossesAtSafeZAndStops() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        let t = Self.walk(["G28 X6 Y6", "G0 Z{HOME_Z}", "M30"])
        #expect(Self.close(t.points, [Vec3(5, 1, s), Vec3(6, 6, s)]), "\(t.points)")
        #expect(t.unmodelledFrom == "G28 X6 Y6")
    }

    @Test func theIncrementalReferenceEndingMovesNowhereKnown() {
        let t = Self.walk(["G91 G28 Z0", "G28 X0 Y0", "G90", "M30"])
        #expect(t.points.isEmpty, "\(t.points)")
        #expect(t.unmodelledFrom == "G91 G28 Z0")
    }

    @Test func movesAreWalkedInFooterOrder() {
        let mc = MachineCoordinates(job: Self.job())
        let s = mc.safeZ, h = mc.homeZ
        let xyFirst = Self.walk(["G0 X{HOME_X} Y{HOME_Y}", "G0 Z{HOME_Z}", "M30"])
        #expect(Self.close(xyFirst.points, [Vec3(5, 1, s), Vec3(0, 0, s), Vec3(0, 0, h)]), "\(xyFirst.points)")
        let split = Self.walk(["G0 X2", "G0 Y3", "M30"])
        #expect(Self.close(split.points, [Vec3(5, 1, s), Vec3(2, 1, s), Vec3(2, 3, s)]), "\(split.points)")
    }

    @Test func aMillimetrePostOnAnInchJobGivesInches() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        let t = Self.walk(["G28 X25.4 Y50.8", "M30"], profile: BuiltInPosts.avidMach4MM)
        #expect(Self.close(t.points, [Vec3(5, 1, s), Vec3(1, 2, s)]), "\(t.points)")
    }

    @Test(arguments: ["G28", "G30", "G53 G0 Z0", "G2 X1 Y1 I1 J0", "M6", "M0", "M1", "/G0 Z1", "G43 H1",
                      "G49", "G92 X0", "G54", "M98 P100", "G81 X1 Y1 Z-0.1 R0.1"])
    func anUnknownBlockStopsTheWalkAtItsLine(line: String) {
        let t = Self.walk([line, "G0 X0 Y0", "M30"])
        #expect(t.points.isEmpty, "\(t.points)")
        #expect(t.unmodelledFrom == line)
    }

    @Test func aMillimetreUnitsCodeOnAnInchPostStops() {
        let t = Self.walk(["G21", "G0 X0 Y0", "M30"])
        #expect(t.unmodelledFrom == "G21")
        let own = Self.walk(["G20", "G0 X0 Y0", "M30"])
        #expect(own.unmodelledFrom == nil)
        #expect(own.points.count == 2)
    }

    @Test func nothingAfterTheProgramEndIsWalked() {
        let mc = MachineCoordinates(job: Self.job())
        let t = Self.walk(["G0 Z{HOME_Z}", "M30", "G0 X9 Y9"])
        #expect(Self.close(t.points, [Vec3(5, 1, mc.safeZ), Vec3(5, 1, mc.homeZ)]), "\(t.points)")
        #expect(t.unmodelledFrom == nil)
        let same = Self.walk(["G0 X0 Y0 M30", "G0 X9 Y9"])
        #expect(Self.close(same.points, [Vec3(5, 1, mc.safeZ), Vec3(0, 0, mc.safeZ)]), "\(same.points)")
        #expect(same.unmodelledFrom == nil)
    }

    @Test func incrementalMovesAddToThePosition() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        let t = Self.walk(["G91", "G0 X1", "G90", "G0 Y2", "M30"])
        #expect(Self.close(t.points, [Vec3(5, 1, s), Vec3(6, 1, s), Vec3(6, 2, s)]), "\(t.points)")
    }

    @Test func axisWordsAloneFollowTheModeTheProgramLeft() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        // Below safe Z the builder writes a G0 retract.
        let afterRetract = Self.walk(["X0 Y0", "M30"])
        #expect(Self.close(afterRetract.points, [Vec3(5, 1, s), Vec3(0, 0, s)]), "\(afterRetract.points)")
        let high = Vec3(5, 1, s + 0.5)
        let tool = ToolLibrary.seeded.tools[0]
        let fed = Toolpath(name: "A", kind: .profile, tool: tool, moves: [.linear(to: high, feed: 50)])
        let afterFeed = Self.walk(["X0 Y0", "M30"], end: high, toolpaths: [fed])
        #expect(Self.close(afterFeed.points, [high, Vec3(0, 0, high.z)]), "\(afterFeed.points)")
        #expect(afterFeed.feedLegs == [1])
        let rapid = Toolpath(name: "A", kind: .profile, tool: tool, moves: [.rapid(to: high)])
        let afterRapid = Self.walk(["X0 Y0", "M30"], end: high, toolpaths: [rapid])
        #expect(Self.close(afterRapid.points, [high, Vec3(0, 0, high.z)]), "\(afterRapid.points)")
    }

    @Test func approachZResolvesFromTheJob() {
        let mc = MachineCoordinates(job: Self.job())
        let t = Self.walk(["G0 Z{APPROACH_Z}", "M30"], approach: 1.5)
        #expect(Self.close(t.points, [Vec3(5, 1, mc.safeZ), Vec3(5, 1, mc.z(aboveTop: 1.5))]), "\(t.points)")
    }

    @Test func unparsedTextStopsTheWalk() {
        let t = Self.walk(["G0 X1 Y1 #5", "M30"])
        #expect(t.unmodelledFrom == "G0 X1 Y1 #5")
        #expect(t.points.isEmpty)
    }

    /// G4's X is the dwell time on Syntec, not an axis: the next G0 goes straight from the retract point.
    @Test func aDwellsXIsNotAMove() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        let t = Self.walk(["G4 X1.0", "G0 X1 Y3", "M30"], profile: BuiltInPosts.syntecInch)
        #expect(Self.close(t.points, [Vec3(5, 1, s), Vec3(1, 3, s)]), "\(t.points)")
        #expect(t.unmodelledFrom == nil)
    }

    /// A feed move is walked as one, so it is checked where it goes; the legs it makes are listed.
    @Test func feedMovesAreWalkedAndMarked() {
        let s = MachineCoordinates(job: Self.job()).safeZ
        let t = Self.walk(["G1 X2 F50", "Y3", "G0 X0 Y0", "M30"])
        #expect(Self.close(t.points, [Vec3(5, 1, s), Vec3(2, 1, s), Vec3(2, 3, s), Vec3(0, 0, s)]), "\(t.points)")
        #expect(t.feedLegs == [1, 2])
        #expect(t.unmodelledFrom == nil)
        #expect(Self.walk().feedLegs.isEmpty)
    }
}
