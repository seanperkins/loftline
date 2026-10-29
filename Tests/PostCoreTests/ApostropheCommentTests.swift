import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// The `'` comment style NcStudio reads (#109, #99 item 5).
@Suite struct ApostropheCommentTests {
    /// The Avid mm post's fields under an id no built-in family claims.
    func apostrophePost(_ change: (inout PostProfile) -> Void = { _ in }) -> PostProfile {
        var p = BuiltInPosts.avidMach4MM
        p.id = "my-apostrophe-post"
        p.commentStyle = .apostrophe
        change(&p)
        return p
    }

    @Test func apostropheCommentRunsToTheEndOfTheLine() {
        let p = apostrophePost()
        #expect(p.comment("Bob's (1/4) bit") == "' Bob's [1/4] bit")
        #expect(!p.comment("a\nb").contains("\n"))
    }

    @Test func oneMessageFormPerStyle() {
        #expect(PostProfile.CommentStyle.parentheses.message("x") == "(MSG, x)")
        #expect(PostProfile.CommentStyle.semicolon.message("x") == "; x")
        #expect(PostProfile.CommentStyle.apostrophe.message("x") == "' x")
        #expect(PostProfile.defaultPause(for: .apostrophe) == ["M5", "' {MESSAGE}", "{STOP}"])
        #expect(PostProfile.defaultPause(for: .parentheses) == ["M5", "(MSG, {MESSAGE})", "{STOP}"])
        #expect(PostProfile.defaultPause(for: .semicolon) == ["M5", "; {MESSAGE}", "{STOP}"])
    }

    func words(_ text: String, _ mode: GCodeParser.Comments) -> [String] {
        GCodeParser.parse(text, comments: mode).blocks.flatMap(\.words).map { "\($0.letter)\(NumberFormat.compact($0.value, maxDecimals: 3))" }
    }

    func garbage(_ text: String, _ mode: GCodeParser.Comments) -> [String] {
        GCodeParser.parse(text, comments: mode).garbage.map(\.text)
    }

    @Test func eachModeReadsItsComments() {
        #expect(words("G1 X1 ' Y2", .standard) == ["G1", "X1", "Y2"])
        #expect(garbage("G1 X1 ' Y2", .standard) == ["'"])
        #expect(words("(Bob's) G1 X1", .standard) == ["G1", "X1"] && garbage("(Bob's) G1 X1", .standard).isEmpty)

        #expect(words("G1 X1 ' (Y2", .apostrophe) == ["G1", "X1"] && garbage("G1 X1 ' (Y2", .apostrophe).isEmpty)
        #expect(garbage("(note) G1 X1", .apostrophe).contains("(") && garbage("(note) G1 X1", .apostrophe).contains(")"))
        #expect(garbage("G1 X1 ; c", .apostrophe).contains(";"))

        #expect(words("(Bob's 1/4\" bit) T2 M6", .any) == ["T2", "M6"])
        #expect(words("T2 ' (note", .any) == ["T2"] && garbage("T2 ' (note", .any).isEmpty)
        #expect(words("T2 ; ' x", .any) == ["T2"])

        for mode in [GCodeParser.Comments.standard, .apostrophe, .any] {
            #expect(GCodeParser.parse("%", comments: mode).blocks.isEmpty && GCodeParser.parse("%", comments: mode).garbage.isEmpty)
            let r = GCodeParser.parse("/G1 Z-1", comments: mode)
            #expect(r.blockDeleteLines == [1] && r.blocks.first?.value("Z") == -1)
        }
    }

    func validated(_ text: String, _ p: PostProfile) -> [GCodeIssue] {
        GCodeValidator(profile: p, job: PostFixtures.job(), units: .millimeter).validate(gcode: text)
    }

    @Test func garbageIsAnErrorOnlyInAnApostrophePost() {
        let p = apostrophePost()
        let comment = validated("G21\n(note)\nG0 Z5\n", p).filter { $0.severity == .error }
        #expect(comment.contains { $0.message.contains("reads only ' comments") })
        let other = validated("G21\n#100=5\n", p).filter { $0.severity == .error }
        #expect(other.contains { $0.message.hasPrefix("Unrecognised text") })
        for text in ["G21\n(note)\nG0 Z5\n", "G21\n#100=5\n", "G21\nG0 Z5 ' x\n"] {
            let avid = validated(text, BuiltInPosts.avidMach4MM)
            #expect(!avid.contains { $0.severity == .error && ($0.message.contains("comments") || $0.message.contains("Unrecognised")) })
        }
        #expect(validated("G21\nG0 Z5 ' x\n", BuiltInPosts.avidMach4MM).contains { $0.severity == .warning && $0.message.contains("Unrecognised") })
    }

    @Test func anImportedApostrophePostWithAParenthesisPauseIsRefused() throws {
        let p = try PostProfile.fromJSON(apostrophePost { $0.pause = ["M5", "(MSG, {MESSAGE})", "{STOP}"] }.toJSON())
        var job = PostFixtures.postJob()
        job.toolpaths[0].pauseAfter = PauseStep(message: "Flip")
        let text = try TemplatePostProcessor(profile: p).post(job)
        let v = GCodeValidator(profile: p, job: job.job, units: job.units)
        #expect(v.validate(gcode: text).contains { $0.severity == .error })
    }

    @Test func anM6InsideAnApostropheCommentIsNoToolChange() {
        let p = apostrophePost { $0.toolChange = ["M5", "' then M6 by hand", "M0"] }
        #expect(ToolChangeZ.setsZ(p) == false)
    }

    @Test func anApostropheLineIsNeverNumbered() throws {
        let p = apostrophePost { $0.lineNumbers = true }
        let lines = try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()).split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix("'") })
        #expect(lines.allSatisfy { !($0.hasPrefix("N") && $0.contains("'")) })
        var w = GCodeWriter(profile: p, safeZ: 1)
        w.code("   ' x")
        #expect(w.lines == ["' x"])
    }

    @Test func theReaderSkipsAnApostropheComment() {
        let r = GCodeReader.read("G21\nG0 Z5\n' T2 X5\nG1 X10 F100\n", units: .millimeter, startZ: 5)
        let moves = r.segments.flatMap(\.moves)
        #expect(!moves.contains { $0.target?.x == 5 })
        #expect(r.segments.allSatisfy { $0.toolNumber != 2 })
        #expect(GCodeReader.toolComments("' Change to Tool: Vbit\nT3 M6", comments: .any)[2] == "Change to Tool: Vbit")
        #expect(GCodeReader.toolComments("(a) ' b T3 M6", comments: .any)[1] == "a")
        #expect(GCodeReader.toolComments("T3 M6 ' b (a)", comments: .any)[1] == "b (a)")
    }

    @Test func placeholdersFollowThePostsCommentStyle() {
        func problems(_ line: String, _ style: PostProfile.CommentStyle) -> [String] {
            PostDraftReport.placeholderProblems(line, template: .toolChange, label: "Tool change", style: style)
        }
        #expect(problems("' {TOOL_NAME}", .apostrophe).isEmpty)
        #expect(problems("( {TOOL_NAME} )", .apostrophe).contains { $0.contains("must be inside a comment") })
        for style in [PostProfile.CommentStyle.parentheses, .semicolon] {
            #expect(problems("' {TOOL_NAME}", style).contains { $0.contains("must be inside a comment") }, "\(style)")
        }
        #expect(problems("( {TOOL_NAME} )", .parentheses).isEmpty && problems("; {TOOL_NAME}", .semicolon).isEmpty)
    }

    @Test func onlyTheApostropheBoundaryIsLocked() {
        var avid = BuiltInPosts.avidMach4Inch
        avid.id = "avid-pro6096-mach4-inch-custom-1"
        avid.controller = nil
        var toApostrophe = avid
        toApostrophe.commentStyle = .apostrophe
        #expect(toApostrophe.postProblem?.contains("keep the comment style") == true)
        var toSemicolon = avid
        toSemicolon.commentStyle = .semicolon
        #expect(toSemicolon.postProblem == nil)
        var carbide = BuiltInPosts.carbideMotionMM
        carbide.id = "carbide-motion-mm-custom-1"
        carbide.commentStyle = .parentheses
        #expect(carbide.postProblem == nil)
    }

    @Test func anApostrophePostCannotDeclareAController() throws {
        var mine = apostrophePost()
        mine.id = "my-post"
        mine.controller = .mach4
        let p = try PostProfile.fromJSON(mine.toJSON())
        let message = try #require(p.postProblem)
        #expect(message.contains("' comments"))
        #expect(throws: PostError.invalidPost(message)) { try TemplatePostProcessor(profile: p).post(PostFixtures.postJob()) }
        #expect(PostDraftReport.make(p).problems.filter { $0.contains(message) }.count == 1)
    }

    @Test func anApostropheProgramWritesNoOtherComment() throws {
        let p = apostrophePost { $0.toolChange = ["M5", "' Change to Tool: {TOOL_NAME}", "T{T} M6"] }
        var job = PostFixtures.postJob()
        job.toolpaths[0].pauseAfter = PauseStep(message: "Flip (side)")
        job.toolpaths[0].moves.append(.dwell(seconds: 2))
        job.job.twoSided = TwoSidedSetup()
        #expect(Set(job.toolpaths.map(\.tool.number)).count >= 2)
        let text = try TemplatePostProcessor(profile: p).post(job)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(!text.contains("(") && !text.contains(";"))
        #expect(lines.filter { $0.contains("'") }.allSatisfy { $0.hasPrefix("'") || $0.hasPrefix("' ") })
        #expect(lines.contains { $0.hasPrefix("' Change to Tool:") })
        let issues = GCodeValidator(profile: p, job: job.job, units: job.units).validate(gcode: text)
        #expect(!issues.contains { $0.severity == .error }, "\(issues)")
    }

    @Test func anApostrophePostNeedsSchemaFour() throws {
        #expect(apostrophePost().requiredSchemaVersion == 4)
        let both = apostrophePost {
            $0.dwell = "G4 P{MILLISECONDS}"
            $0.toolLengthOffset = "G0 G43 Z{APPROACH_Z} H{T}"
        }
        #expect(both.requiredSchemaVersion == 4)
        let json = String(decoding: try both.toJSON(), as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 4"))
        #expect(json.contains("\"commentStyle\" : \"apostrophe\""))
    }
}
