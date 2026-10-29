import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The engine options the ShopBot, Syntec and Haas posts need (#99 items 2 and 7; spec
/// docs/specs/2026-10-28-shopbot-syntec-haas-posts-design.md): a program wrapper, `{APPROACH_Z}`, `{DECIMAL_SECONDS}`, and no
/// dwell line for a dwell that prints as zero.
@Suite struct PostEngineOptions2Tests {
    func custom(_ change: (inout PostProfile) -> Void) -> PostProfile {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "options-2"
        change(&p)
        return p
    }

    func lines(_ profile: PostProfile, zZero: ZZeroMode = .materialTop, approachHeight: Double? = nil,
               toolpaths: [Toolpath]? = nil) throws -> [String] {
        let job = PostJob(name: "Options", units: .inch, job: PostFixtures.job(zZero: zZero),
                          toolpaths: toolpaths ?? PostFixtures.toolpaths(zZero: zZero), approachHeight: approachHeight)
        return try TemplatePostProcessor(profile: profile).post(job).split(separator: "\n").map(String.init)
    }

    /// The fixture's first toolpath with a dwell of `seconds` after its plunge.
    func dwelling(_ seconds: Double) -> [Toolpath] {
        var tps = PostFixtures.toolpaths()
        tps[0].moves.insert(.dwell(seconds: seconds), at: 2)
        return tps
    }

    // MARK: The program wrapper

    @Test func thePreludeComesFirstAndIsNeverNumbered() throws {
        let p = custom { $0.prelude = ["%", "O1000", "( Wrapper )"]; $0.lineNumbers = true }
        let out = try lines(p)
        #expect(Array(out.prefix(3)) == ["%", "O1000", "( Wrapper )"])
        #expect(out.contains { $0.hasPrefix("N10 G20") })
    }

    @Test func aPercentFooterLineIsNeverNumbered() throws {
        let p = custom { $0.footer += ["%"]; $0.lineNumbers = true }
        let out = try lines(p)
        #expect(out.last == "%")
        #expect(out[out.count - 2].hasPrefix("N") && out[out.count - 2].hasSuffix("M30"))
    }

    // MARK: {APPROACH_Z}

    @Test func approachZIsTheApproachHeightInBothZeroModes() throws {
        let p = custom { $0.useToolLengthOffset = true; $0.toolLengthOffset = "G0 G43 Z{APPROACH_Z} H{T}" }
        // Approach 1.5 in above the top, safe Z 0.2 in: material top at Z0, spoilboard zero puts the top at Z0.75.
        #expect(try lines(p, zZero: .materialTop, approachHeight: 1.5).contains("G0 G43 Z1.5000 H1"))
        #expect(try lines(p, zZero: .spoilboard, approachHeight: 1.5).contains("G0 G43 Z2.2500 H1"))
        #expect(try lines(p, zZero: .materialTop).contains("G0 G43 Z0.2000 H1"))
        #expect(try lines(p, zZero: .spoilboard).contains("G0 G43 Z0.9500 H1"))
    }

    // MARK: {DECIMAL_SECONDS}

    @Test func decimalSecondsAlwaysCarryADot() throws {
        let p = custom { $0.dwell = "G4 X{DECIMAL_SECONDS}" }
        #expect(p.dwellValues(seconds: 3)["DECIMAL_SECONDS"] == "3.000")
        #expect(p.dwellValues(seconds: 0.25)["DECIMAL_SECONDS"] == "0.250")
        #expect(p.dwellValues(seconds: 3600)["DECIMAL_SECONDS"] == "3600.000")
        let out = try lines(p, toolpaths: dwelling(0.25))
        #expect(out.contains("G4 X3.000"))   // the spin-up
        #expect(out.contains("G4 X0.250"))
    }

    // MARK: A dwell that prints as zero

    @Test func aDwellThatPrintsAsZeroIsNotWritten() throws {
        for dwell in ["G4 P{SECONDS}", "G4 P{MILLISECONDS}", "G4 X{DECIMAL_SECONDS}"] {
            let p = custom { $0.dwell = dwell; $0.spindleDwellSeconds = 0 }
            #expect(!p.writesDwell(seconds: 0.0004) && p.writesDwell(seconds: 0.001) && !p.writesDwell(seconds: 0), "\(dwell)")
            #expect(!(try lines(p, toolpaths: dwelling(0.0004))).contains { $0.hasPrefix("G4 ") }, "\(dwell)")
            #expect(try lines(p, toolpaths: dwelling(0.001)).contains { $0.hasPrefix("G4 ") }, "\(dwell)")
        }
    }

    // MARK: Dwell forms (spec E3)

    @Test func theDwellFormIsTheWordAndThePlaceholder() {
        #expect(PostProfile.dwellForm("G4 P{SECONDS}")! == ("P", "SECONDS"))
        #expect(PostProfile.dwellForm("p{MILLISECONDS}  G04")! == ("P", "MILLISECONDS"))
        #expect(PostProfile.dwellForm("G4 X{DECIMAL_SECONDS}")! == ("X", "DECIMAL_SECONDS"))
        #expect(PostProfile.dwellForm("G4 P3") == nil && PostProfile.dwellForm("G1 P{SECONDS}") == nil)
    }

    @Test func decimalSecondsGoOnlyWithXAndXOnlyWithDecimalSeconds() {
        // An Avid copy (a P-seconds family) may not take Syntec's X form; no post may write a whole X or a dotted P.
        #expect(custom { $0.id = BuiltInPosts.avidMach4Inch.id + "-custom-1"; $0.dwell = "G4 X{DECIMAL_SECONDS}" }.dwellProblem != nil)
        var own = BuiltInPosts.avidMach4Inch
        own.id = "my-own-post"
        for dwell in ["G4 P{DECIMAL_SECONDS}", "G4 X{SECONDS}", "G4 X{MILLISECONDS}"] {
            var p = own
            p.dwell = dwell
            #expect(p.dwellProblem != nil, "\(dwell)")
        }
        own.dwell = "G4 X{DECIMAL_SECONDS}"
        #expect(own.dwellProblem == nil)   // a post of the owner's own may dwell in decimal seconds
    }

    @Test func secondsInThePreludeOfAMillisecondPostAreRefused() throws {
        var p = BuiltInPosts.massoG3Inch
        p.id = BuiltInPosts.massoG3Inch.id + "-custom-1"
        p.prelude = ["G4 P{SECONDS}"]
        #expect(p.dwellProblem?.contains("cannot also write {SECONDS}") == true)
        let read = try PostProfile.fromJSON(p.toJSON())
        #expect(throws: PostError.self) { try TemplatePostProcessor(profile: read).post(PostFixtures.postJob()) }
    }

    @Test func secondsElsewhereInADecimalSecondsPostAreRefused() {
        var p = BuiltInPosts.avidMach4Inch
        p.id = "my-own-post"
        p.dwell = "G4 X{DECIMAL_SECONDS}"
        p.footer = ["G4 P{SECONDS}"] + p.footer
        #expect(p.dwellProblem != nil)
    }

    // MARK: Reading G70/G71 and G4 X (spec E2, E3)

    func issues(_ gcode: String, _ profile: PostProfile) -> [String] {
        GCodeValidator(profile: profile, job: PostFixtures.job(), units: .inch).validate(gcode: gcode).map(\.message)
    }

    @Test func g70AndG71AreUnitsOnlyForAPostThatWritesThem() {
        let syntec = custom { $0.unitsCodes = .g70g71 }
        let program = "G70\nG90\nG0 Z0.2\nM30\n"
        #expect(!issues(program, syntec).contains { $0.contains("never sets units") || $0.contains("not a code this validator knows") })
        #expect(issues("G71\nG90\nG0 Z5\nM30\n", syntec).contains { $0.contains("Program units mm differ") })
        #expect(issues("G90\nG0 Z0.2\nM30\n", syntec).contains { $0.contains("G70/G71") })
        // Elsewhere G70 is a cycle (Haas, Fanuc lathes): still a word this validator cannot vouch for.
        let avid = issues(program, BuiltInPosts.avidMach4Inch)
        #expect(avid.contains { $0.contains("G70 is not a code this validator knows") })
        #expect(avid.contains { $0.contains("never sets units") })
    }

    @Test func theReaderReadsGFourXAsSecondsAndWarnsOnG70() {
        let read = GCodeReader.read("G21\nG90\nG4 X3.000\nM30\n", units: .inch, startZ: 0.2)
        let moves = read.segments.flatMap(\.moves)
        #expect(moves.contains { if case .dwell(let s) = $0 { return s == 3 }; return false })
        #expect(!moves.contains { $0.target != nil })
        let g70 = GCodeReader.read("G70\nG90\nG0 Z0.2\nM30\n", units: .inch, startZ: 0.2)
        #expect(g70.warnings.filter { $0.contains("G70/G71") }.count == 1)
    }

    /// A drill's dwell that prints as zero is not in the program: the toolpath check must not forget the hole for it either.
    @Test func aDwellThatIsNotWrittenDoesNotForgetTheHole() {
        let p = custom { $0.dwell = "G4 P{MILLISECONDS}" }
        let mc = MachineCoordinates(job: PostFixtures.job())
        let d = mc.z(depth: 0.5), up = mc.safeZ
        func check(_ dwell: Double?) -> [GCodeIssue] {
            var moves: [Move] = [.rapid(to: Vec3(1, 1, up)), .linear(to: Vec3(1, 1, d), feed: 20), .rapid(to: Vec3(1, 1, up))]
            if let dwell { moves.append(.dwell(seconds: dwell)) }
            moves += [.rapid(to: Vec3(1, 1, d + 0.05)), .linear(to: Vec3(1, 1, d - 0.2), feed: 20), .rapid(to: Vec3(1, 1, up))]
            let tp = Toolpath(name: "Peck", kind: .drill, tool: PostFixtures.endMill, moves: moves)
            return GCodeValidator(profile: p, job: PostFixtures.job(), units: .inch).validate(toolpaths: [tp])
        }
        #expect(check(0.0004) == check(nil))
        #expect(check(0.001) != check(nil))   // a written dwell does forget it (the test reaches the rule)
    }
}
