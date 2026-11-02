import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// A spindle at S0 is stopped on GRBL, Buildbotics and the other RPM controllers (#99 item 10): no program starts or cuts at it.
@Suite struct SpindleZeroTests {
    static let zeroStart = "Spindle speed S0 leaves the spindle stopped"
    static let offCut = "Cutting move with the spindle off"

    static func job(rpm: Double) -> PostJob {
        var j = PostFixtures.postJob()
        j.toolpaths = j.toolpaths.map { var t = $0; t.spindleRPM = rpm; return t }
        return j
    }

    @Test(arguments: [0, 0.5, 0.99, Double.nan])
    func everyPostRefusesASpeedBelowOneRPM(rpm: Double) {
        for post in BuiltInPosts.all {
            #expect(throws: PostError.spindleStopped(toolpath: "Profile 1"), "\(post.id)") {
                try TemplatePostProcessor(profile: post).post(Self.job(rpm: rpm))
            }
        }
    }

    @Test func oneRPMPostsAsS1() throws {
        var grbl = BuiltInPosts.genericGRBLInch
        grbl.id = "custom-grbl"
        let text = try TemplatePostProcessor(profile: grbl).post(Self.job(rpm: 1))
        #expect(text.contains("S1"))
        #expect(!text.contains("S0"))
    }

    static func issues(_ body: String, profile: PostProfile = BuiltInPosts.genericGRBLInch) -> [GCodeIssue] {
        GCodeValidator(profile: profile, job: PostFixtures.job(), units: .inch)
            .validate(gcode: "G20\nG90\nG0 Z0.2\n" + body + "G0 Z0.2\nM5\nM30\n")
    }

    static func count(_ issues: [GCodeIssue], _ prefix: String, _ severity: GCodeIssue.Severity = .error) -> Int {
        issues.filter { $0.severity == severity && $0.message.hasPrefix(prefix) }.count
    }

    @Test func aStartAtS0IsOneError() {
        for profile in [BuiltInPosts.genericGRBLInch, BuiltInPosts.avidMach4Inch] {
            let found = Self.issues("M3 S0\n", profile: profile)
            #expect(Self.count(found, Self.zeroStart) == 1, "\(profile.id)")
            #expect(found.filter { $0.severity == .error }.count == 1, "\(profile.id): \(found)")
        }
    }

    /// S set on an earlier block is the speed M3 starts at.
    @Test func anM3AfterS0IsAStartAtS0() {
        let found = Self.issues("S0\nM3\n")
        #expect(Self.count(found, Self.zeroStart) == 1, "\(found)")
        // A speed out of range is reported once, where it is set, not again at the M3.
        let high = Self.issues("S99999\nM3\n")
        #expect(Self.count(high, "Spindle speed S99999 outside") == 1, "\(high)")
    }

    @Test func aCutAfterAStartAtS0IsACutWithTheSpindleOff() {
        let found = Self.issues("M3 S0\nG0 X1 Y1\nG1 Z-0.1 F30\nG1 X2 F60\n")
        #expect(Self.count(found, Self.zeroStart) == 1)
        let cuts = found.filter { $0.message.hasPrefix(Self.offCut) }
        #expect(!cuts.isEmpty)
        // The message must not blame a missing M3: this program has one.
        #expect(cuts.allSatisfy { !$0.message.contains("no M3 before") }, "\(cuts)")
    }

    @Test func aLaterS0StopsTheSpindleForTheCut() {
        let found = Self.issues("M3 S18000\nS0\nG0 X1 Y1\nG1 Z-0.1 F30\n")
        #expect(Self.count(found, Self.offCut) >= 1, "\(found)")
        let sameBlock = Self.issues("M3 S18000\nG0 X1 Y1\nG1 Z-0.1 F30 S0\n")
        #expect(Self.count(sameBlock, Self.offCut) >= 1, "\(sameBlock)")
    }

    @Test func aFooterS0AfterTheLastCutIsFine() {
        let found = Self.issues("M3 S18000\nG0 X1 Y1\nG1 Z-0.1 F30\nG1 X2 F60\nG0 Z0.2\nS0\n")
        #expect(found.filter { $0.severity == .error }.isEmpty, "\(found)")
    }

    @Test func aPlainM3IsOnlyTheExistingWarning() {
        let found = Self.issues("M3\nG0 X1 Y1\nG1 Z-0.1 F30\n")
        #expect(found.filter { $0.severity == .error }.isEmpty, "\(found)")
        #expect(Self.count(found, "Spindle started (M3/M4) with no speed", .warning) == 1)
    }
}
