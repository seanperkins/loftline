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

    func tooled(_ number: Int, moves: Bool = true) -> Toolpath {
        var t = PostFixtures.endMill
        t.number = number
        var tp = Toolpath(name: "T\(number)", kind: .profile, tool: t,
                          moves: moves ? [.rapid(to: Vec3(1, 1, 0.2)), .linear(to: Vec3(1, 1, -0.1), feed: 30)] : [])
        tp.coolant = nil
        return tp
    }

    /// MASSO gives T0 to the dry-run laser and T101 up to other heads: a main-spindle bit must be T1–T100 (#107).
    @Test func massoToolNumbersMustBeOneToAHundred() {
        for p in [BuiltInPosts.massoG3Inch, { var q = BuiltInPosts.massoG3MM; q.id = "masso-g3-mm-custom-1"; return q }()] {
            #expect(errors(p, [tooled(0)]).contains { $0.contains("T0") }, "\(p.id)")
            #expect(errors(p, [tooled(101)]).contains { $0.contains("T101") }, "\(p.id)")
            #expect(errors(p, [tooled(1), tooled(100)]).isEmpty, "\(p.id)")
            #expect(errors(p, [tooled(1), tooled(101, moves: false)]).isEmpty, "\(p.id): an empty toolpath does not post")
        }
        #expect(errors(BuiltInPosts.avidMach4Inch, [tooled(101)]).isEmpty)
    }

    @Test func massoHasNoToolLengthOffset() {
        var p = BuiltInPosts.massoG3Inch
        p.useToolLengthOffset = true
        #expect(errors(p, [tooled(1)]).contains { $0.contains("G43") })
    }

    @Test func uccncWarnsWhichUnitsItsProfileMustUse() {
        for (p, unit) in [(BuiltInPosts.uccncInch, "inches"), (BuiltInPosts.uccncMM, "millimetres")] {
            let w = DialectChecks.issues(toolpaths: [tooled(1)], profile: p).filter { $0.severity == .warning }
            #expect(w.count == 1 && w[0].message.hasPrefix(DialectChecks.uccncUnitsWarningPrefix) && w[0].message.contains(unit))
        }
    }

    /// CNC12 documents dwells of 0.01 to 327.67 s (#103).
    @Test func centroidDwellsStayInTheirDocumentedRange() {
        func dwelling(_ s: Double) -> Toolpath {
            var tp = tooled(1)
            tp.moves.append(.dwell(seconds: s))
            return tp
        }
        let p = BuiltInPosts.centroidMM
        #expect(errors(p, [dwelling(400)]).contains { $0.contains("327.67") })
        #expect(errors(p, [dwelling(0.005)]).contains { $0.contains("0.01") })
        #expect(errors(p, [dwelling(3), dwelling(327.67)]).isEmpty)
        #expect(errors(BuiltInPosts.avidMach4Inch, [dwelling(400)]).isEmpty)
    }

    @Test func aDuplicateKeepsItsCoolantRule() {
        var p = BuiltInPosts.carbideMotionMM
        p.id = "carbide-motion-mm-custom-3"
        #expect(errors(p, [path("Pocket", coolant: .mist)]).count == 1)
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
        // The same shape in other units, or within rounding, is the same cutter.
        var nose = PostFixtures.endMill
        nose.shape = .bullNose(cornerRadius: 0.05)
        var metric = nose.converted(to: .millimeter)
        metric.id = UUID()
        #expect(nose.hasSameGeometry(as: metric))
        var rounded = nose
        rounded.id = UUID(); rounded.shape = .bullNose(cornerRadius: 0.05000001)
        #expect(nose.hasSameGeometry(as: rounded))
    }

    /// A toolpath with no moves is never posted (`ProgramBuilder`), so its coolant is never written.
    @Test func anEmptyToolpathsCoolantIsNotReported() {
        var empty = path("Empty", coolant: .mist)
        empty.moves = []
        #expect(errors(BuiltInPosts.carbideMotionMM, [path("Plain", coolant: nil), empty]).isEmpty)
    }
}
