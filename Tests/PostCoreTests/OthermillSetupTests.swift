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

    func issues(_ job: JobSetup, units: LengthUnit = .inch, moves: [Toolpath]? = nil, toolpaths: [Toolpath]? = nil,
                profile: PostProfile = BuiltInPosts.othermillInch, approach: Double? = nil) -> [GCodeIssue] {
        let tps = toolpaths ?? [inside(units)]
        return OthermillSetup.issues(job: job, units: units, moves: moves ?? tps, toolpaths: tps, profile: profile,
                                     approachHeight: approach)
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

    @Test func aMoveOrAHomeBeyondTheBedIsAnError() {
        let far = path([Vec3(6, 1, 0.2), Vec3(6, 1, -0.1), Vec3(6, 1.2, -0.1), Vec3(6, 1.2, 0.2)])   // span 0.2, at X 6
        #expect(errors(issues(job(), toolpaths: [far])).contains { $0.contains("X travel") })
        var j = job()
        j.width = 5
        let home = Toolpath(name: "Move home (end of program)", kind: .profile, tool: tool,
                            moves: [.rapid(to: Vec3(3, 2, 0.5)), .rapid(to: Vec3(6, 0, 0.5))])
        #expect(errors(issues(j, moves: [inside(), home], toolpaths: [inside()])).contains { $0.contains("X travel") })
        let deep = path([Vec3(1, 4.6, 0.2), Vec3(1, 4.6, -0.1)])
        #expect(errors(issues(job(), toolpaths: [deep])).contains { $0.contains("Y travel") })
    }

    @Test func movesAtExactlyTheBedEdgeAreNotErrorsInEitherUnit() {
        let edge = path([Vec3(0, 0, 0.2), Vec3(0, 0, -0.1), Vec3(5.5, 4.5, -0.1), Vec3(5.5, 4.5, 0.2)])
        #expect(errors(issues(job(), toolpaths: [edge], profile: BuiltInPosts.othermillMM)).isEmpty)
        let mm = path([Vec3(0, 0, 5), Vec3(0, 0, -2), Vec3(139.7, 114.3, -2), Vec3(139.7, 114.3, 5)])
        #expect(errors(issues(job(.millimeter), units: .millimeter, toolpaths: [mm], profile: BuiltInPosts.othermillInch)).isEmpty)
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

    @Test(arguments: [LengthUnit.inch, .millimeter]) func theStockPlusTheHighestZMustFitTheZTravel(_ u: LengthUnit) {
        let f = LengthUnit.inch.factor(to: u)
        let w = { (j: JobSetup, top: Double, approach: Double?) -> Bool in
            let tp = path([Vec3(1 * f, 1 * f, top * f), Vec3(1 * f, 1 * f, -0.05 * f)])
            return warnings(issues(j, units: u, toolpaths: [tp], approach: approach.map { $0 * f }))
                .contains { $0.hasPrefix(OthermillSetup.zEnvelopeWarningPrefix) }
        }
        var j = job(u)
        j.thickness = 0.75 * f; j.homeZ = 0.8 * f
        #expect(w(j, 0.8, nil))                          // 0.75 + 0.8 = 1.55 > 1.35
        j.homeZ = 0.6 * f
        #expect(!w(j, 0.6, nil))                         // 0.75 + 0.6 = 1.35, the boundary
        j.homeZ = 0.5 * f; j.safeZ = 0.2 * f
        #expect(w(j, 0.2, 0.7))                          // a clamp raises the approach: 0.75 + 0.7 = 1.45
        j.thickness = 0.25 * f
        #expect(!w(j, 0.5, nil))                         // 0.25 + 0.5
    }
}
