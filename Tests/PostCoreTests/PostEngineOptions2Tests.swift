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
}
