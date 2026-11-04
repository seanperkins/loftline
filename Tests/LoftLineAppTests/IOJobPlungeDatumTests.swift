import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOJobPlungeDatumTests {
    func rapidZs(_ kind: OperationKind, gap: Double?, offset: Vec2? = nil) throws -> (zs: [Double], tps: [Toolpath], LoftLineProject) {
        var p = AppTestSupport.project()
        p.document.job.plungeGap = gap
        p.document.job.datumOffset = offset
        let op = try #require(OperationFactory.make(kind: kind, project: p, library: .seeded,
                                                    shapeIDs: [p.document.shapes[0].id]))
        p.operations = [op]
        let r = ToolpathCalculator.calculate(op, project: p, library: .seeded, designRevision: 0, rapidRate: 200)
        #expect(r.error == nil)
        let zs = r.toolpaths.flatMap(\.moves).compactMap { m -> Double? in
            if case .rapid(let to) = m { return to.z }
            return nil
        }
        return (zs, r.toolpaths, p)
    }

    @Test func plungeGapSetsTheRapidDescentHeight() throws {
        let def = try rapidZs(.profile, gap: nil)
        #expect(def.zs.contains { abs($0 - 0.05) < 1e-9 })
        let custom = try rapidZs(.profile, gap: 0.15)
        #expect(custom.zs.contains { abs($0 - 0.15) < 1e-9 })
        #expect(!custom.zs.contains { abs($0 - 0.05) < 1e-9 })
        // V-carve plunges from safe Z by default; with a gap it rapids down to it first.
        let v0 = try rapidZs(.vcarve, gap: nil)
        #expect(!v0.zs.contains { abs($0 - 0.1) < 1e-9 })
        let v = try rapidZs(.vcarve, gap: 0.1)
        #expect(v.zs.contains { abs($0 - 0.1) < 1e-9 })
        let post = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch)
            .post(PostJob(name: "t", units: .inch, job: v.2.document.job, toolpaths: v.tps))
        #expect(GCodeValidator(profile: BuiltInPosts.avidMach4Inch, job: v.2.document.job, units: .inch)
            .validate(gcode: post).filter { $0.severity == .error }.isEmpty)
    }

    @Test func gapIsCappedAtSafeZAndValidated() {
        var job = JobSetup()
        job.plungeGap = 5
        #expect(job.effectivePlungeGap(default: 0.05) == job.safeZ)
        var form = JobSetupForm(document: Document())
        form.job.plungeGap = 1
        #expect(!form.problems.isEmpty)
        form.job.plungeGap = 0.1
        #expect(form.problems.isEmpty)
        let mm = form.job.scaled(by: 25.4)
        #expect(abs(mm.plungeGap! - 2.54) < 1e-9)
    }

    @Test func datumOffsetMovesMachineZero() throws {
        var job = JobSetup()
        job.xyOrigin = .lowerLeft
        job.datumOffset = Vec2(1, 2)
        #expect(MachineCoordinates(job: job).machineXY(Vec2(1, 2)) == Vec2(0, 0))
        let plain = try rapidZs(.profile, gap: nil)
        let shifted = try rapidZs(.profile, gap: nil, offset: Vec2(1, 2))
        let a = plain.tps[0].xyBounds, b = shifted.tps[0].xyBounds
        // The two loops start at different points (home is relative to the datum), so their
        // fitted corner arcs differ within the arc tolerance; the bounds include arc bulges.
        #expect(a.min.isApproximatelyEqual(to: b.min + Vec2(1, 2), tolerance: 1e-3))
        let text = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch)
            .post(PostJob(name: "t", units: .inch, job: shifted.2.document.job, toolpaths: shifted.tps))
        #expect(text.contains("XY datum offset: X1.0000 Y2.0000"))
        #expect(!(try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch)
            .post(PostJob(name: "t", units: .inch, job: plain.2.document.job, toolpaths: plain.tps))).contains("datum offset"))
    }
}
