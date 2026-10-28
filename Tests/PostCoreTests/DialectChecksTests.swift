import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// Built-in controllers' own limits checked at export (#104, #105, #114).
@Suite struct DialectChecksTests {
    func path(_ name: String, coolant: Coolant?) -> Toolpath {
        var tp = Toolpath(name: name, kind: .profile, tool: PostFixtures.endMill,
                          moves: [.rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.1), feed: 30)])
        tp.coolant = coolant
        return tp
    }

    func errors(_ p: PostProfile, _ tps: [Toolpath]) -> [String] {
        DialectChecks.issues(toolpaths: tps, profile: p).filter { $0.severity == .error }.map(\.message)
    }

    @Test func coolantOnAControllerWithoutItIsOneErrorWithItsReason() {
        let tps = [path("Pocket A", coolant: .mist), path("Pocket B", coolant: .air), path("Plain", coolant: nil)]
        for p in [BuiltInPosts.carbideMotionInch, BuiltInPosts.carbideMotionMM] {
            let e = errors(p, tps)
            #expect(e.count == 1, "\(p.id)")
            #expect(e.first?.contains("Carbide Motion ignores M7 and does not support M8") == true)
            #expect(e.first?.contains("Pocket A") == true && e.first?.contains("Pocket B") == true && e.first?.contains("Plain") == false)
        }
        for p in [BuiltInPosts.othermillInch, BuiltInPosts.othermillMM] {
            let e = errors(p, tps)
            #expect(e.count == 1 && e.first?.contains("its G-code reference lists M7, M8 and M9 as unsupported") == true, "\(p.id)")
        }
        for p in [BuiltInPosts.onefinityBBInch, BuiltInPosts.genericGRBLMM, BuiltInPosts.avidMach4Inch] {
            #expect(errors(p, tps).isEmpty, "\(p.id)")
        }
        #expect(errors(BuiltInPosts.carbideMotionMM, [path("Plain", coolant: nil)]).isEmpty)
    }

    /// Two cutters that differ only in tip diameter or in shape are different tools: one T number for both is an error.
    @Test func toolsDifferingInTipOrShapeMayNotShareANumber() {
        let base = PostFixtures.vBit
        var tip = base
        tip.id = UUID(); tip.tipDiameter = base.tipDiameter + 0.05
        var shaped = base
        shaped.id = UUID(); shaped.shape = .bullNose(cornerRadius: 0.02)
        var twin = base
        twin.id = UUID()
        #expect(!base.hasSameGeometry(as: tip) && !base.hasSameGeometry(as: shaped) && base.hasSameGeometry(as: twin))
        func tp(_ t: Tool, _ name: String) -> Toolpath {
            Toolpath(name: name, kind: .profile, tool: t, moves: [.rapid(to: Vec3(1, 1, 0.2)),
                                                                 .linear(to: Vec3(1, 1, -0.1), feed: 30)])
        }
        let v = GCodeValidator(profile: BuiltInPosts.carbideMotionInch, job: PostFixtures.job(), units: .inch)
        for other in [tip, shaped] {
            #expect(v.validate(toolpaths: [tp(base, "a"), tp(other, "b")])
                .contains { $0.severity == .error && $0.message.contains("different geometry") })
        }
        #expect(v.validate(toolpaths: [tp(base, "a"), tp(twin, "b")]).contains { $0.severity == .warning })
    }
}
