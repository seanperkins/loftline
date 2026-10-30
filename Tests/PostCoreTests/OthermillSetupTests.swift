import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// What the Bantam Tools software assumes of a program (#114, spec Decision 2): file X0 Y0 Z0 at the stock's front-left top.
@Suite struct OthermillSetupTests {
    let tool = PostFixtures.endMill

    /// A small job in `units`: 4 x 3 x 0.25 in (or its mm equivalent), the setup the software expects.
    func job(_ units: LengthUnit = .inch) -> JobSetup {
        let f = LengthUnit.inch.factor(to: units)
        return JobSetup(width: 4 * f, height: 3 * f, thickness: 0.25 * f, safeZ: 0.2 * f, homeZ: 0.5 * f)
    }

    /// One toolpath through `points` (document units, machine coordinates), cutting at the first point's Z.
    func path(_ points: [Vec3], name: String = "Cut", coolant: Coolant? = nil) -> Toolpath {
        var tp = Toolpath(name: name, kind: .profile, tool: tool,
                          moves: [.rapid(to: points[0])] + points.dropFirst().map { .linear(to: $0, feed: 30) })
        tp.coolant = coolant
        return tp
    }

    func inside(_ units: LengthUnit = .inch) -> Toolpath {
        let f = LengthUnit.inch.factor(to: units)
        return path([Vec3(1 * f, 1 * f, 0.2 * f), Vec3(1 * f, 1 * f, -0.1 * f), Vec3(3 * f, 2 * f, -0.1 * f),
                     Vec3(3 * f, 2 * f, 0.2 * f)])
    }

    /// `toolpaths` is kept so each case reads as the job it describes; where the program goes is the validator's (#119,
    /// `TravelWindowTests`).
    func issues(_ job: JobSetup, units: LengthUnit = .inch, toolpaths: [Toolpath]? = nil,
                profile: PostProfile = BuiltInPosts.othermillInch) -> [GCodeIssue] {
        OthermillSetup.issues(job: job, units: units, profile: profile)
    }

    func errors(_ i: [GCodeIssue]) -> [String] { i.filter { $0.severity == .error }.map(\.message) }
    func warnings(_ i: [GCodeIssue]) -> [String] { i.filter { $0.severity == .warning }.map(\.message) }

    @Test(arguments: [LengthUnit.inch, .millimeter]) func thePlainSetupIsClean(_ u: LengthUnit) {
        for p in [BuiltInPosts.othermillInch, BuiltInPosts.othermillMM] {
            #expect(issues(job(u), units: u, toolpaths: [inside(u)], profile: p).isEmpty, "\(u) \(p.id)")
        }
    }

    @Test(arguments: [LengthUnit.inch, .millimeter]) func spoilboardZeroIsAnError(_ u: LengthUnit) {
        var j = job(u)
        j.zZero = .spoilboard
        #expect(errors(issues(j, units: u, toolpaths: [inside(u)])).contains { $0.contains("material top") })
    }

    @Test func everyOtherOriginIsAnError() {
        for origin in XYOrigin.allCases where origin != .lowerLeft {
            var j = job()
            j.xyOrigin = origin
            #expect(errors(issues(j)).contains { $0.contains("lower left") }, "\(origin)")
        }
    }

    @Test(arguments: [LengthUnit.inch, .millimeter]) func aDatumOffsetIsAnErrorAndNilOrZeroIsNot(_ u: LengthUnit) {
        var j = job(u)
        j.datumOffset = Vec2(0.5, 0)
        #expect(errors(issues(j, units: u, toolpaths: [inside(u)])).contains { $0.contains("datum offset") })
        j.datumOffset = .zero
        #expect(issues(j, units: u, toolpaths: [inside(u)]).isEmpty)
        j.datumOffset = nil   // a tiled export's tiles
        #expect(issues(j, units: u, toolpaths: [inside(u)]).isEmpty)
    }

    @Test func theBottomSideIsCheckedWithItsOwnZZero() {
        var j = job()
        j.twoSided = TwoSidedSetup(bottomZZero: .spoilboard)
        #expect(issues(j.forSide(.top)).isEmpty)
        #expect(errors(issues(j.forSide(.bottom))).contains { $0.contains("material top") })
    }

    @Test func otherPostsAreNotChecked() {
        var j = job()
        j.zZero = .spoilboard
        j.xyOrigin = .center
        #expect(issues(j, profile: BuiltInPosts.genericGRBLMM).isEmpty)
        #expect(issues(j, profile: BuiltInPosts.avidMach4Inch).isEmpty)
    }

    @Test func machineAppliedCopiedAndEditedPostsAreStillChecked() {
        var j = job()
        j.zZero = .spoilboard
        var edited = BuiltInPosts.othermillInch
        edited.footer.append("(edited)")
        let copy = try! PostProfile.fromJSON(BuiltInPosts.othermillInch.toJSON())
        var duplicate = BuiltInPosts.othermillInch
        duplicate.id = "othermill-inch-custom-1"
        for p in [BuiltInMachines.othermillPro.applied(to: BuiltInPosts.othermillInch), copy, edited, duplicate] {
            #expect(!errors(issues(j, profile: p)).isEmpty, "\(p.id)")
        }
    }

    @Test func aBiggerMachineOrPostIsAWarning() {
        let w = { (p: PostProfile) in warnings(issues(job(), profile: p)).filter { $0.hasPrefix(OthermillSetup.limitsWarningPrefix) } }
        #expect(w(BuiltInMachines.avidPRO6096.applied(to: BuiltInPosts.othermillInch)).count == 1)
        var wide = BuiltInPosts.othermillInch
        wide.limits.xTravel = 24   // a user file reusing the id, no machine
        #expect(w(wide).count == 1)
        func pro(_ change: (inout MachineDefinition) -> Void) -> PostProfile {
            var m = BuiltInMachines.othermillPro
            change(&m)
            return m.applied(to: BuiltInPosts.othermillMM)
        }
        #expect(w(pro { $0.maxRPM = 30000 }).count == 1)
        #expect(w(pro { $0.maxFeed = 600 }).count == 1)
        #expect(w(pro { $0.rapidRate = 200 }).count == 1)
        #expect(w(pro { $0.minRPM = 6000 }).count == 1)
        for m in [BuiltInMachines.othermillPro, BuiltInMachines.othermill] {
            for p in [BuiltInPosts.othermillInch, BuiltInPosts.othermillMM] {
                #expect(w(m.applied(to: p)).isEmpty, "\(m.id) \(p.id)")
            }
        }
    }
}
