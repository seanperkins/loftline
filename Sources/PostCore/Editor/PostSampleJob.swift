import CADCore
import CAMCore
import Foundation

/// The fixed job the post editor posts a draft with (spec "The sample"): an inch document 4 x 3 x 0.5 in, material-top zero,
/// three toolpaths that cover the output paths: A (tool 1, a clockwise and a counter-clockwise arc, a pause after it), B
/// (tool 1), C (tool 2, Mist). The pause sits between toolpaths (the builder drops one after the last) and the change from B
/// to C has no pause before it. No toolpath starts at the sheet's centre, the touch-off spot of the probe pass. Its speeds
/// fit the draft's spindle range and feed limit, so the sample tests the dialect, not the post's fallback machine numbers.
public enum PostSampleJob {
    public static let names = (a: "Sample A", b: "Sample B", c: "Sample C")
    static let tool1 = ToolLibrary.seeded.tools[0]   // T1 1/4" end mill
    static let tool2 = ToolLibrary.seeded.tools[1]   // T2 1/8" end mill

    public static func job(for draft: PostProfile, probing: Bool = false) -> PostJob {
        var setup = JobSetup(width: 4, height: 3, thickness: 0.5, xyOrigin: .lowerLeft, zZero: .materialTop,
                             safeZ: 0.2, homeZ: 0.8, home: Vec2(0, 0))
        if probing { setup.touchOffSpot = Vec2(2, 1.5) }
        let mc = MachineCoordinates(job: setup)
        let safe = mc.safeZ, deep = mc.z(depth: 0.1), shallow = mc.z(depth: 0.05)
        let rpm = min(max(18000, max(1, draft.minRPM)), draft.maxRPM)
        let maxFeed = draft.maxFeed * draft.units.factor(to: .inch)
        func f(_ v: Double) -> Double { min(v, maxFeed) }
        var a = Toolpath(name: names.a, kind: .profile, tool: tool1, spindleRPM: rpm, moves: [
            .rapid(to: Vec3(0.5, 0.5, safe)),
            .linear(to: Vec3(0.5, 0.5, deep), feed: f(30)),
            .linear(to: Vec3(1.5, 0.5, deep), feed: f(100)),
            .arcCCW(to: Vec3(1.5, 1.5, deep), center: Vec2(1.5, 1.0), feed: f(100)),
            .arcCW(to: Vec3(0.5, 1.5, deep), center: Vec2(1.0, 1.5), feed: f(100)),
            .linear(to: Vec3(0.5, 0.5, deep), feed: f(100)),
            .rapid(to: Vec3(0.5, 0.5, safe)),
        ])
        a.pauseAfter = PauseStep(message: "Check the sample")
        let b = Toolpath(name: names.b, kind: .profile, tool: tool1, spindleRPM: rpm, moves: [
            .rapid(to: Vec3(2.5, 0.5, safe)),
            .linear(to: Vec3(2.5, 0.5, deep), feed: f(30)),
            .linear(to: Vec3(3.5, 0.5, deep), feed: f(100)),
            .rapid(to: Vec3(3.5, 0.5, safe)),
        ])
        var c = Toolpath(name: names.c, kind: .profile, tool: tool2, spindleRPM: rpm, moves: [
            .rapid(to: Vec3(2.5, 2.5, safe)),
            .linear(to: Vec3(2.5, 2.5, shallow), feed: f(20)),
            .linear(to: Vec3(3.5, 2.5, shallow), feed: f(60)),
            .rapid(to: Vec3(3.5, 2.5, safe)),
        ])
        // A controller with no coolant (the Othermill, Carbide Motion) gets a sample without one.
        c.coolant = BuiltInPosts.family(of: draft.id).flatMap { BuiltInPosts.noCoolantReasons[$0] } == nil ? .mist : nil
        return PostJob(name: "Sample", units: .inch, job: setup, toolpaths: [a, b, c])
    }

    /// The draft with its machine numbers widened to at least 100 x 100 x 10 in (in its units): a machine replaces them.
    static func widened(_ draft: PostProfile) -> PostProfile {
        var p = draft
        let inch = LengthUnit.inch.factor(to: draft.units)
        p.limits = MachineLimits(xTravel: max(draft.limits.xTravel, 100 * inch), yTravel: max(draft.limits.yTravel, 100 * inch),
                                 zTravel: max(draft.limits.zTravel, 10 * inch), maxSpoilboardCut: draft.limits.maxSpoilboardCut)
        return p
    }
}
