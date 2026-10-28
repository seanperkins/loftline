import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The validator walks the park-and-probe sequence state by state (spec §6): the builder's own programs pass clean,
/// and every dropped, misplaced or wrong step is an error.
@Suite struct ProbeValidatorTests {
    typealias B = ProbeSequenceBuilderTests

    struct Program {
        var text: String
        var profile: PostProfile
        var job: JobSetup
        var units: LengthUnit

        var issues: [GCodeIssue] { GCodeValidator(profile: profile, job: job, units: units).validate(gcode: text) }
        var errors: [GCodeIssue] { issues.filter { $0.severity == .error } }

        /// The program with `old` (the first occurrence after `after`, if given) replaced by `new`.
        func replacing(_ old: String, with new: String, occurrence: Int = 1) -> Program {
            var lines = text.components(separatedBy: "\n")
            var seen = 0
            guard let i = lines.indices.first(where: { lines[$0] == old && { seen += 1; return seen == occurrence }() }) else {
                Issue.record("no line '\(old)' (occurrence \(occurrence))"); return self
            }
            if new.isEmpty { lines.remove(at: i) } else { lines[i] = new }
            var p = self
            p.text = lines.joined(separator: "\n")
            return p
        }
        func removing(_ line: String, occurrence: Int = 1) -> Program { replacing(line, with: "", occurrence: occurrence) }
        func inserting(_ new: String, before line: String, occurrence: Int = 1) -> Program {
            replacing(line, with: new + "\n" + line, occurrence: occurrence)
        }
        /// The line after the `n`th line that starts with `prefix`.
        func line(after prefix: String, occurrence: Int = 1) -> String {
            let lines = text.components(separatedBy: "\n")
            let hits = lines.indices.filter { lines[$0].hasPrefix(prefix) }
            return lines[hits[occurrence - 1] + 1]
        }
    }

    static func mach4(_ tps: [Toolpath]? = nil, profile: PostProfile = B.profile(BuiltInPosts.avidMach4Inch)) throws -> Program {
        let tps = tps ?? [B.cut("A"), B.cut("B", tool: PostFixtures.vBit, at: 3)]
        let job = B.job()
        let text = try TemplatePostProcessor(profile: profile).post(PostJob(name: "P", units: .inch, job: job, toolpaths: tps))
        return Program(text: text, profile: profile, job: job, units: .inch)
    }

    static func grbl(workOffset: Int = 1) throws -> Program {
        var probe = B.grbl
        probe.workOffset = workOffset
        let profile = B.profile(BuiltInPosts.genericGRBLMM, machine: BuiltInMachines.genericGRBL, probe: probe)
        let job = B.job(.millimeter, spot: Vec2(150, 100))
        let tps = [B.cut("A", at: 10, job: job), B.cut("B", tool: PostFixtures.vBit, at: 40, job: job)]
        let text = try TemplatePostProcessor(profile: profile).post(PostJob(name: "P", units: .millimeter, job: job, toolpaths: tps))
        return Program(text: text, profile: profile, job: job, units: .millimeter)
    }

    static let placementPrefix = "(MSG, Clip the probe lead"

    // MARK: Clean

    @Test func theBuildersProgramsAreClean() throws {
        let m = try Self.mach4(), g = try Self.grbl()
        #expect(m.issues.isEmpty, "\(m.issues)")
        #expect(g.issues.isEmpty, "\(g.issues)")
    }

    @Test func lineNumbersAreIgnoredWhenMatching() throws {
        var numbered = B.profile(BuiltInPosts.avidMach4Inch)
        numbered.lineNumbers = true
        let p = try Self.mach4(profile: numbered)
        #expect(p.text.contains("N") && p.issues.isEmpty, "\(p.issues)")
    }

    @Test func customFooterPauseAndPreambleAreClean() throws {
        var custom = BuiltInPosts.avidMach4Inch
        custom.footer = ["G53 G0 Z0", "M5", "M30"]
        custom.pause = ["G53 G0 Z0", "M5", "(MSG, {MESSAGE})", "{STOP}"]
        custom.preamble.append("G54")
        var probe = B.mach4
        probe.workOffset = 2
        custom.toolChangeProbe = .on(probe)   // set directly: an edited post would be refused when applied
        var a = B.cut("A")
        a.pauseAfter = PauseStep(message: "Look")
        let p = try Self.mach4([a, B.cut("B", at: 3), B.cut("C", tool: PostFixtures.vBit, at: 5)], profile: custom)
        #expect(p.issues.isEmpty, "\(p.issues)")
    }

    @Test func aTooDeepCutAfterTheSecondToolIsStillCaught() throws {
        let p = try Self.mach4()
        let lines = p.text.components(separatedBy: "\n")
        let deepest = try #require(lines.last { $0.hasPrefix("G1") && $0.contains("Z-") })
        let deeper = deepest.replacingOccurrences(of: #"Z-[0-9.]+"#, with: "Z-5.0000", options: .regularExpression)
        #expect(!p.replacing(deepest, with: deeper).errors.isEmpty)
    }

    // MARK: Errors

    func expectError(_ p: Program, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!p.errors.isEmpty, "\(what): no error", sourceLocation: sourceLocation)
    }

    @Test func wrongZero() throws {
        let g = try Self.grbl()
        expectError(g.replacing("G10 L20 P1 Z12.000", with: "G10 L20 P1 Z11.000"), "wrong G10 value")
        expectError(g.replacing("G10 L20 P1 Z12.000", with: "G10 L20 P2 Z12.000"), "wrong P")
        let m = try Self.mach4()
        expectError(m.replacing("M199 P0.5000", with: "M199 P0.4000"), "wrong macro P")
        expectError(m.replacing("M199 P0.5000", with: "G10 L20 P1 Z0.5000"), "G10 L20 on Mach4")
        expectError(g.inserting("G10 L20 P1 Z12.000", before: "M2"), "a zero outside probed")
    }

    @Test func workOffset() throws {
        let m = try Self.mach4()
        let placementStop = m.line(after: Self.placementPrefix)
        #expect(placementStop == "M0")
        // A G55 after the placement stop: the macro would zero G55 and the recovery line switch back to G54.
        let lines = m.text.components(separatedBy: "\n")
        let i = try #require(lines.firstIndex { $0.hasPrefix(Self.placementPrefix) })
        var withG55 = lines
        withG55.insert("G55", at: i + 2)
        expectError(Program(text: withG55.joined(separator: "\n"), profile: m.profile, job: m.job, units: m.units), "G55 before the zero")
        let firstM3 = try #require(lines.first { $0.hasPrefix("M3 S") })
        expectError(m.inserting("G55", before: firstM3), "cuts in another offset")
    }

    @Test func droppedOrMisplacedSteps() throws {
        let m = try Self.mach4()
        expectError(m.removing("G53 G0 Z0.0000"), "G53 X/Y not after the traverse height")
        expectError(m.inserting("T2", before: "G53 G0 Z0.0000"), "T outside parked")
        expectError(m.removing("G53 G0 X2.0000 Y-2.0000").removing("G53 G0 Z-0.5000"), "no park")
        expectError(m.removing("M0"), "no swap stop")
        let placement = m.text.components(separatedBy: "\n").firstIndex { $0.hasPrefix(Self.placementPrefix) }!
        var noPlacementStop = m.text.components(separatedBy: "\n")
        noPlacementStop.remove(at: placement + 1)
        expectError(Program(text: noPlacementStop.joined(separator: "\n"), profile: m.profile, job: m.job, units: m.units),
                    "no placement stop")
        expectError(m.removing("G0 Z0.7000"), "no clear move")
        let removal = m.line(after: "(MSG, Remove the touch plate")
        #expect(removal == "M0")
        var noRemovalStop = m.text.components(separatedBy: "\n")
        noRemovalStop.remove(at: noRemovalStop.firstIndex { $0.hasPrefix("(MSG, Remove the touch plate") }! + 1)
        expectError(Program(text: noRemovalStop.joined(separator: "\n"), profile: m.profile, job: m.job, units: m.units),
                    "no removal stop")
        expectError(m.inserting("M3 S18000", before: "T1"), "spindle on at the swap")
        expectError(m.inserting("M3 S18000", before: "G91"), "spindle on at the probe")
    }

    @Test func badProbes() throws {
        let m = try Self.mach4()
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 X-0.5000 F5.0"), "probe on X")
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z0.5000 F5.0"), "probe upward")
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z-0.5000 F5.0 M3"), "probe with M3")
        expectError(m.removing("G91"), "no G91 before")
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z-0.5000 F5.0\nG91").removing("G91"), "G91 after, not before")
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z-0.6000 F5.0"), "probe longer than allowed")
        expectError(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z-0.5000 F5.1"), "probe faster than allowed")
        // At the rounding edge: within half a digit passes.
        #expect(m.replacing("G31 Z-0.5000 F5.0", with: "G31 Z-0.50004 F5.04").errors.isEmpty)
        expectError(m.removing("M199 P0.5000"), "Mach4 unit without the zero macro")
        expectError(m.removing("G17 G40 G49 G80 G90 G94 G91.1 G20 G54"), "no recovery line")
        expectError(m.replacing("G17 G40 G49 G80 G90 G94 G91.1 G20 G54", with: "G17 G40 G49 G80 G90 G94 G90.1 G20 G54"),
                    "recovery line with the other arc word")
        let g = try Self.grbl()
        expectError(g.inserting("G38.2 Z-5 F50", before: "M2"), "probe outside placed")
        expectError(g.replacing("G0 Z17.000", with: "Z17.000"), "axis block with no motion word after the probe")
    }

    @Test func wrongPositions() throws {
        let m = try Self.mach4()
        expectError(m.replacing("G53 G0 X2.0000 Y-2.0000", with: "G53 G0 X3.0000 Y-2.0000"), "park not the computed one")
        expectError(m.replacing("G0 X6.0000 Y4.0000", with: "G0 X6.5000 Y4.0000"), "spot not the computed one")
    }

    @Test func missingSequences() throws {
        // The first sequence deleted: the post's plain program checked against a probing profile.
        let plainText = try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch)
            .post(PostJob(name: "P", units: .inch, job: B.job(), toolpaths: [B.cut("A")]))
        let plain = Program(text: plainText, profile: B.profile(BuiltInPosts.avidMach4Inch), job: B.job(), units: .inch)
        expectError(plain, "the first sequence deleted")
        // A later sequence deleted with its T kept.
        let m = try Self.mach4()
        var lines = m.text.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0] == "G90 G92.1 G54" }
        let removals = lines.indices.filter { lines[$0].hasPrefix("(MSG, Remove the touch plate") }
        let range = (starts[1] + 1)...(removals[1] + 1)
        let t = lines[range].first { $0.hasPrefix("T") }!
        lines.removeSubrange(range)
        lines.insert(t, at: starts[1] + 1)
        expectError(Program(text: lines.joined(separator: "\n"), profile: m.profile, job: m.job, units: m.units),
                    "a later sequence deleted, its T kept")
    }

    @Test func noDescentAtTheSpotAfterTheRemovalStop() throws {
        let m = try Self.mach4()
        // The re-entry's cross to the first toolpath: the line after the climb that follows the removal stop.
        let lines = m.text.components(separatedBy: "\n")
        let removal = try #require(lines.firstIndex { $0.hasPrefix("(MSG, Remove the touch plate") })
        let cross = lines[removal + 3]
        #expect(cross.hasPrefix("X"))
        var noCross = lines
        noCross.remove(at: removal + 3)
        expectError(Program(text: noCross.joined(separator: "\n"), profile: m.profile, job: m.job, units: m.units),
                    "descent at the spot")
    }

    @Test func withoutAProbeTodaysWarningsStand() throws {
        let g = try Self.grbl()
        var plain = g
        plain.profile = BuiltInPosts.genericGRBLMM
        #expect(plain.issues.contains { $0.message.contains("changes the coordinate system") })
        // A GRBL footer that lifts to machine Z 0, not its traverse height, keeps today's warning.
        #expect(g.inserting("G53 G0 Z0", before: "M2").issues.contains { $0.message.contains("changes the coordinate system") })
    }
}
