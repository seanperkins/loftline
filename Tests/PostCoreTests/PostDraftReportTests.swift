import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The post editor's report: static rules first, then a fixed sample job posted and validated, with the stops checked in the
/// parsed program (spec "The report").
@Suite struct PostDraftReportTests {
    func draft(_ change: (inout PostProfile) -> Void = { _ in }, base: PostProfile = BuiltInPosts.avidMach4Inch) -> PostDraftReport {
        var p = base
        p.id = "draft"
        change(&p)
        return PostDraftReport.make(p)
    }

    func refused(_ change: (inout PostProfile) -> Void, base: PostProfile = BuiltInPosts.avidMach4Inch, _ what: String,
                 sourceLocation: SourceLocation = #_sourceLocation) {
        let r = draft(change, base: base)
        #expect(!r.canSave, "\(what): accepted", sourceLocation: sourceLocation)
    }

    func accepted(_ change: (inout PostProfile) -> Void, base: PostProfile = BuiltInPosts.avidMach4Inch, _ what: String,
                  sourceLocation: SourceLocation = #_sourceLocation) {
        let r = draft(change, base: base)
        #expect(r.canSave, "\(what): \(r.problems)", sourceLocation: sourceLocation)
    }

    @Test func everyBuiltInIsClean() {
        for p in BuiltInPosts.all {
            let r = PostDraftReport.make(p)
            #expect(r.problems.isEmpty && r.issues.isEmpty, "\(p.name): \(r.problems) \(r.issues)")
            #expect(r.program?.isEmpty == false)
        }
    }

    @Test func unchangedDuplicatesAreClean() {
        for p in BuiltInPosts.all {
            var d = p
            d.id = p.id + "-custom-1"
            d.controller = BuiltInPosts.probeController(for: p)
            let r = PostDraftReport.make(d)
            #expect(r.problems.isEmpty && r.issues.isEmpty, "\(p.name) duplicate: \(r.problems) \(r.issues)")
        }
    }

    @Test func fixedCodes() {
        refused({ $0.arcCW = "G3"; $0.arcCCW = "G2" }, "swapped arc codes")
        refused({ $0.arcCW = "" }, "an empty arc code")
        refused({ $0.rapid = "G0 F600" }, "G0 F600")
        refused({ $0.rapid = "G0 ;" }, "G0 ;")
        refused({ $0.spindleOn = "M4 S{S}" }, "M4 S{S}")
        refused({ $0.spindleOn = "M30 S{S}" }, "M30 S{S}")
        refused({ $0.spindleOn = "M3 (S{S})" }, "M3 (S{S})")
        refused({ $0.dwell = "G40 P{SECONDS}" }, "G40 P{SECONDS}")
        refused({ $0.spindleOff = "M8" }, "spindle off M8")
        accepted({ $0.dwell = "G04 P{SECONDS}"; $0.spindleOn = "M03 S{S}"; $0.rapid = "G00"; $0.linear = "G01" }, "zero-padded codes")
        accepted({ $0.spindleOn = "S{S} M3" }, "S before M3")
    }

    @Test func placeholders() {
        refused({ $0.footer.append("(T{T})") }, "{T} in the footer")
        refused({ $0.dwell = "G4 P{SAFE_Z}" }, "{SAFE_Z} in the dwell")
        refused({ $0.spindleOff = "M5 {S}" }, "{S} in spindle off")
        refused({ $0.preamble.append("(oops {)") }, "a lone {")
        refused({ $0.toolChange = ["M5", "T{T} M6 {TOOL_NAME}"] }, "{TOOL_NAME} outside a comment")
        refused({ $0.pause = ["M5", "(MSG, {MESSAGE} {STOP})"] }, "{STOP} inside a comment")
        refused({ $0.preamble.append("v{POST_VERSION}") }, "{POST_VERSION} outside a comment")
        accepted({ $0.preamble.append("(post {POST_NAME} v{POST_VERSION})"); $0.footer.insert("; job {JOB_NAME}", at: 0) },
                 "text placeholders in comments")
    }

    @Test func textRules() {
        refused({ $0.name = "   " }, "a blank name")
        refused({ $0.fileExtension = "t.p" }, "an extension with a dot")
        refused({ $0.preamble.append("(it’s)") }, "a curly quote in a template")
        accepted({ $0.name = "Shop – inch"; $0.version = "1.0) M3" }, "name and version reach the program only comment-safe")
    }

    @Test func numberRules() {
        refused({ $0.decimals = 2 }, "decimals 2 on an inch post")
        refused({ $0.decimals = 7 }, "decimals 7")
        refused({ $0.feedDecimals = 4 }, "feed decimals 4")
        refused({ $0.arcTolerance = 0.05 }, "arc tolerance 0.05 in")
        refused({ $0.arcTolerance = 0.000001 }, "arc tolerance under half a digit")
        refused({ $0.limits.xTravel = .infinity }, "an infinite travel")
        refused({ $0.maxRPM = 0.1; $0.minRPM = 0 }, "max RPM 0.1")
        refused({ $0.minRPM = 30000 }, "min RPM above max")
        refused({ $0.spindleDwellSeconds = -1 }, "negative dwell")
        accepted({ $0.decimals = 2 }, base: BuiltInPosts.avidMach4MM, "decimals 2 on an mm post")
    }

    @Test func controllerWithToolLengthOffsetIsRefused() {
        refused({ $0.controller = .mach4; $0.useToolLengthOffset = true }, "controller with G43")
    }

    @Test func toolChangesMustStopOrChangeTheTool() {
        refused({ $0.toolChange = ["M5"] }, "tool change M5 only")
        refused({ $0.toolChange = [] }, "no tool change")
        refused({ $0.toolChange = ["M5", "M6"] }, "M6 with no T")
        refused({ $0.toolChange = ["M5", "M1"] }, "an optional stop")
        refused({ $0.toolChange = ["M5", "T2 M6"] }, "always tool 2")
        refused({ $0.toolChange = ["M5", "T2 M6", "M0"] }, "always tool 2, with a stop")
        refused({ $0.toolChange = ["T{T} M6"] }, "M5 removed: the change happens with the spindle running")
        accepted({ $0.toolChange = ["M5", "T{T}", "M6"] }, "T and M6 on separate lines")
        accepted({ _ in }, base: BuiltInPosts.genericGRBLMM, "GRBL: M5 and M0")
    }

    @Test func pausesMustStop() {
        refused({ $0.pause = ["M05"] }, "a pause of M05")
        refused({ $0.pause = ["M5", "(MSG, {MESSAGE})", "M1"] }, "a hard-coded optional stop")
        accepted({ $0.pause = ["M5", "G53 G0 Z0", "(MSG, {MESSAGE})", "{STOP}"] }, "a lift before the stop")
    }

    @Test func programRules() {
        refused({ $0.footer.insert("G21", at: 0) }, "G21 in an inch post's footer")
        refused({ $0.preamble.append("G92 Z10") }, "G92 in the preamble")
        refused({ $0.footer.insert("G53 G0 Z-100", at: 0) }, "a machine-coordinate plunge in the footer")
        let lift = ["G53 G0 Z0", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M30"]
        accepted({ $0.footer = lift }, "a G53 lift in the footer, no controller")
        // With a controller the lift is the probe sequence's traverse height, after which Z is unknown: an X/Y rapid then
        // has no known height. A footer that restates Z first is fine.
        refused({ $0.footer = lift; $0.controller = .mach4 }, "a G53 lift then an XY rapid, with a controller")
        accepted({ $0.footer.insert("G53 G0 Z0", at: 0); $0.controller = .mach4 }, "a G53 lift, then Z restated, with a controller")
    }

    @Test func theSampleFitsThePostsMachineNumbers() {
        accepted({ $0.minRPM = 0; $0.maxRPM = 12000 }, "a 0–12000 RPM post")
        accepted({ $0.limits = MachineLimits(xTravel: 100, yTravel: 100, zTravel: 40, maxSpoilboardCut: 0.5) },
                 base: BuiltInPosts.genericGRBLMM, "a 100 mm travel post")
        accepted({ $0.maxFeed = 1000 }, base: BuiltInPosts.genericGRBLMM, "an mm post with max feed 1000")
    }

    @Test func aDeclaredControllerRunsTheProbeSample() {
        let r = draft({ $0.controller = .mach4 })
        #expect(r.canSave, "\(r.problems)")
        #expect(r.probeProgram?.contains("G31") == true)
        let inchGRBL = draft({ $0.controller = .grbl })
        #expect(inchGRBL.canSave, "inch post declaring GRBL at 4 decimals: \(inchGRBL.problems)")
        #expect(inchGRBL.probeProgram?.contains("G53 G0 Z-0.0393") == true)
    }

    @Test func placeholderTableDrivesTheCaptions() {
        #expect(PostDraftReport.placeholders[.dwell] == ["SECONDS"])
        #expect(PostDraftReport.placeholders[.pause]?.contains("STOP") == true)
        #expect(PostDraftReport.placeholders[.toolChange]?.contains("TOOL_NAME") == true)
        #expect(PostDraftReport.placeholders[.footer]?.contains("T") == false)
    }
}
