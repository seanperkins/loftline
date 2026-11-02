import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// MASSO changes tools only with the spindle stopped and the T word before M6 ("Txx M06 is correct and behaves differently
/// to M06 Txx"), and skips a block-delete line when Block Delete is on (#99 item 11).
@Suite struct MassoToolChangeTests {
    static let spindle = "MASSO needs the spindle stopped (M5) before M6."
    static let order = "MASSO reads the tool number before M6 (T5 M6), not after it (M6 T5): write T{T} M6."
    static let blockDelete = "MASSO skips a block-delete line when Block Delete is on: take the / off the tool change."

    static func masso(copy: Bool = false) -> PostProfile {
        var p = BuiltInPosts.massoG3Inch
        if copy { p.id = "masso-g3-inch-custom-1" }
        return p
    }

    static func issues(_ body: String, profile: PostProfile = masso()) -> [GCodeIssue] {
        GCodeValidator(profile: profile, job: PostFixtures.job(), units: .inch)
            .validate(gcode: "G20\nG90\nG0 Z0.2\n" + body + "M3 S18000\nG0 X1 Y1\nG1 Z-0.1 F30\nG0 Z0.2\nM5\nM30\n")
    }

    static func errors(_ issues: [GCodeIssue], _ message: String) -> Int {
        issues.filter { $0.severity == .error && $0.message == message }.count
    }

    static func anyMasso(_ issues: [GCodeIssue]) -> Bool {
        issues.contains { $0.message.hasPrefix("MASSO") && ($0.message.contains("M6") || $0.message.contains("block-delete")) }
    }

    @Test func aStoppedSpindleAndTBeforeM6Pass() {
        for profile in [Self.masso(), Self.masso(copy: true)] {
            #expect(!Self.anyMasso(Self.issues("M5\nT1 M6\n", profile: profile)), "\(profile.id)")
            #expect(!Self.anyMasso(Self.issues("M5\nT1\nM6\n", profile: profile)), "\(profile.id)")
        }
    }

    @Test func theBuiltInsOwnExportPasses() throws {
        for post in [BuiltInPosts.massoG3Inch, BuiltInPosts.massoG3MM] {
            let job = PostFixtures.postJob()
            let text = try TemplatePostProcessor(profile: post).post(job)
            let found = GCodeValidator(profile: post, job: job.job, units: job.units).validate(gcode: text)
            #expect(!Self.anyMasso(found), "\(post.id): \(found)")
        }
    }

    @Test func anM6WithTheSpindleRunningIsAnError() {
        #expect(Self.errors(Self.issues("M3 S18000\nT1 M6\n"), Self.spindle) == 1)
        #expect(Self.errors(Self.issues("M5\nM3 S18000\nT1 M6\n", profile: Self.masso(copy: true)), Self.spindle) == 1)
    }

    @Test func theTWordMustComeBeforeM6() {
        #expect(Self.errors(Self.issues("M5\nM6 T1\n"), Self.order) == 1)
        #expect(Self.errors(Self.issues("M5\nM6\n"), Self.order) == 1)
        #expect(Self.errors(Self.issues("M5\nT1 M6\nM5\nM6\n"), Self.order) == 1)
    }

    @Test func aToolChangeOnABlockDeleteLineIsAnError() {
        #expect(Self.errors(Self.issues("M5\n/T1 M6\n"), Self.blockDelete) == 1)
        #expect(Self.errors(Self.issues("/M5\nT1 M6\n"), Self.blockDelete) == 1)
    }

    @Test func otherPostsKeepTheWarning() {
        let found = Self.issues("M3 S18000\nM6 T1\n", profile: BuiltInPosts.avidMach4Inch)
        #expect(!Self.anyMasso(found))
        #expect(found.contains { $0.severity == .warning && $0.message.hasPrefix("Tool change (M6) with the spindle running") })
    }
}
