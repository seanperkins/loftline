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

    @Test func anOthermillSampleHasNoCoolant() throws {
        // The Othermill has no coolant (its G-code reference lists M7-M9 as unsupported), so its sample must not show one.
        for p in BuiltInPosts.all where BuiltInPosts.noCoolantReasons[p.id] != nil {
            let program = try #require(PostDraftReport.make(p).program)
            let blocks = GCodeParser.parse(program, comments: .standard).blocks
            #expect(!blocks.contains { $0.has("M", 7) || $0.has("M", 8) || $0.has("M", 9) }, "\(p.id)")
        }
        let avid = try #require(PostDraftReport.make(BuiltInPosts.avidMach4Inch).program)
        #expect(GCodeParser.parse(avid, comments: .standard).blocks.contains { $0.has("M", 7) })   // other posts keep their coolant sample
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

    /// The program wrapper, `{APPROACH_Z}` and `{DECIMAL_SECONDS}` (#106, #110, #111).
    @Test func theProgramStartAndTheNewPlaceholders() {
        accepted({ $0.prelude = ["%", "O1000 ({JOB_NAME})"] }, "a wrapper with the job in a comment")
        refused({ $0.prelude = ["O1000 {JOB_NAME}"] }, "the job's name outside a comment in the program start")
        refused({ $0.prelude = ["%", "O1000 \u{2013} x"] }, "a dash that is not ASCII in the program start")
        refused({ $0.prelude = ["{STOP}"] }, "a placeholder the program start does not have")
        accepted({ $0.useToolLengthOffset = true; $0.toolLengthOffset = "G0 G43 Z{APPROACH_Z} H{T}" }, "the approach height")
        accepted({ $0.dwell = "G4 X{DECIMAL_SECONDS}" }, "Syntec's dwell on a post of the owner's own")
        refused({ $0.dwell = "G4 X{SECONDS}" }, "a whole X dwell")
        refused({ $0.spindleOn = "M3" }, "a plain M3 outside the families that set no speed")
        #expect(PostDraftReport.Template.prelude.label == "Program start")
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

    @Test func aMillisecondDwellIsAccepted() {
        accepted({ $0.dwell = "G4 P{MILLISECONDS}" }, "G4 P{MILLISECONDS}")
        accepted({ $0.dwell = "P{MILLISECONDS} G4" }, "P{MILLISECONDS} G4")
        for bad in ["G4 P{SECONDS}000", "G4 P{MILLISECONDS}0", "G4 X{MILLISECONDS}"] {
            let r = draft({ $0.dwell = bad })
            #expect(r.problems.contains { $0.hasPrefix("Dwell must be G4 P{SECONDS}, G4 P{MILLISECONDS} or G4 X{DECIMAL_SECONDS}") },
                    "\(bad): \(r.problems)")
        }
    }

    @Test func theDwellUnitRulesAreProblems() {
        let problems = { (change: (inout PostProfile) -> Void) in draft(change).problems }
        #expect(problems { $0.dwell = "G4 P{MILLISECONDS}"; $0.pause = ["M5", "G4 P{SECONDS}", "M0"] }
            .contains { $0.contains("cannot also write {SECONDS}") })
        #expect(problems { $0.dwell = "G4 P{MILLISECONDS}"; $0.controller = .grbl }
            .contains { $0.contains("reads G4 P in seconds") })
        #expect(problems { $0.spindleDwellSeconds = 3601 }.contains { $0.contains("0 to 3600 s") })
        accepted({ $0.spindleDwellSeconds = 3600 }, "an hour's dwell")
    }

    @Test func placeholderTableDrivesTheCaptions() {
        #expect(PostDraftReport.placeholders[.dwell] == ["SECONDS", "MILLISECONDS", "DECIMAL_SECONDS"])
        #expect(PostDraftReport.placeholders[.prelude] == PostDraftReport.placeholders[.preamble])
        #expect(PostDraftReport.placeholders[.toolLengthOffset]?.contains("APPROACH_Z") == true)
        #expect(PostDraftReport.placeholders[.pause]?.contains("STOP") == true)
        #expect(PostDraftReport.placeholders[.toolChange]?.contains("TOOL_NAME") == true)
        #expect(PostDraftReport.placeholders[.footer]?.contains("T") == false)
    }

    // MARK: Final review

    @Test func hugeOrFractionalToolNumbersAreRefusedWithoutACrash() {
        refused({ $0.toolChange = ["M5", "T9999999999999999999 M6"] }, "a T number beyond Int")
        refused({ $0.toolChange = ["M5", "T{T}.5 M6"] }, "a fractional tool number")
    }

    @Test func aSemicolonInsideParenthesesIsNotAComment() {
        refused({ $0.version = "M3 S18000"; $0.preamble.append("(note;ignored) {POST_VERSION}") },
                "user text after a semicolon that sits inside a closed comment")
    }

    // MARK: Refused at build (#125): a post that never passes the editor

    /// A post read back from a file, as one in the posts folder or a project's copy is.
    func filePost(_ change: (inout PostProfile) -> Void, base: PostProfile = BuiltInPosts.avidMach4Inch) throws -> PostProfile {
        var p = base
        p.id = "my-post"
        change(&p)
        return try PostProfile.fromJSON(p.toJSON())
    }

    func refusedAtExport(_ p: PostProfile, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(p.placeholderProblem == message, sourceLocation: sourceLocation)
        #expect(throws: PostError.invalidPost(message), sourceLocation: sourceLocation) {
            try TemplatePostProcessor(profile: p).post(PostFixtures.postJob())
        }
        #expect(PostDraftReport.make(p).problems.filter { $0 == message }.count == 1, sourceLocation: sourceLocation)
    }

    static let text = "is text and must be inside a comment, or it could write G-code words."

    @Test func aFilePostWithToolNameOnACodeLineIsRefusedAtExport() throws {
        refusedAtExport(try filePost { $0.toolChange = ["M5", "{TOOL_NAME}", "M0"] }, "Tool change: {TOOL_NAME} \(Self.text)")
    }

    @Test func aStopInsideACommentIsRefusedAtExport() throws {
        refusedAtExport(try filePost { $0.pause = ["M5", "(MSG, {MESSAGE} {STOP})"] }, "Pause: {STOP} inside a comment stops nothing.")
    }

    @Test func spindleOnTextIsRefusedAtExport() throws {
        refusedAtExport(try filePost { $0.spindleOn = "M3 S{S} {TOOL_NAME}" }, "Spindle on: {TOOL_NAME} \(Self.text)")
    }

    @Test func anUnwrittenToolLengthLineIsStillScanned() throws {
        let p = try filePost { $0.useToolLengthOffset = false; $0.toolLengthOffset = "G43 H{T} {TOOL_NAME}" }
        refusedAtExport(p, "Tool length offset: {TOOL_NAME} \(Self.text)")
    }

    @Test func parenthesesAreNoCommentInAnApostrophePost() throws {
        let p = try filePost({ $0.commentStyle = .apostrophe; $0.toolChange = ["M5", "({TOOL_NAME})", "M0"] },
                             base: BuiltInPosts.avidMach4MM)
        refusedAtExport(p, "Tool change: {TOOL_NAME} \(Self.text)")
    }

    @Test func namesATemplateCannotUseStillExport() throws {
        let p = try filePost { $0.preamble = ["G90", "{FOO} {TOOL_NAME}"] }
        #expect(p.placeholderProblem == nil)
        #expect(throws: Never.self) { try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()) }
    }

    @Test func aStrayBraceDoesNotHideThePlaceholder() throws {
        refusedAtExport(try filePost { $0.toolChange = ["M5", "} {TOOL_NAME}", "M0"] }, "Tool change: {TOOL_NAME} \(Self.text)")
    }

    @Test func aLineBreakEndsTheComment() throws {
        let p = try filePost { $0.toolChange = ["M5", "(\nG0 {TOOL_NAME})", "M0"] }
        let message = "Tool change: {TOOL_NAME} \(Self.text)"
        #expect(p.placeholderProblem == message)
        #expect(throws: PostError.invalidPost(message)) { try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()) }
    }

    @Test func commentedTextPostsInEveryStyle() throws {
        let lines: [(PostProfile.CommentStyle, String)] = [(.parentheses, "({TOOL_NAME})"), (.semicolon, "; {TOOL_NAME}"),
                                                           (.semicolon, "({TOOL_NAME})"), (.apostrophe, "' {TOOL_NAME}")]
        for (style, line) in lines {
            let p = try filePost({ $0.commentStyle = style; $0.toolChange = ["M5", line, "M0"] }, base: BuiltInPosts.avidMach4MM)
            #expect(p.placeholderProblem == nil, "\(style) \(line)")
        }
    }

    @Test func noBuiltInHasAPlaceholderProblem() {
        for p in BuiltInPosts.all { #expect(p.placeholderProblem == nil, "\(p.id)") }
    }
}
