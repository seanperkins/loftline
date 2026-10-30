import CADCore
import CAMCore
import Foundation

/// What the post editor says about a draft (spec "The report"): blocking problems, the sample program and its validator
/// issues. Static rules run first; the sample is posted only when none fails, so a typed value never reaches the builder.
public struct PostDraftReport: Sendable {
    public var problems: [String] = []
    public var program: String?
    /// The sample posted with touch-plate tool changes, when the draft declares a controller.
    public var probeProgram: String?
    public var issues: [GCodeIssue] = []
    public var canSave: Bool { problems.isEmpty }

    public init() {}

    /// The templates of a post and the placeholders each one is rendered with.
    public enum Template: String, CaseIterable, Sendable {
        case prelude, preamble, footer, toolChange, toolLengthOffset, spindleOn, pause, dwell

        public var label: String {
            switch self {
            case .prelude: return "Program start"
            case .preamble: return "Preamble"
            case .footer: return "Footer"
            case .toolChange: return "Tool change"
            case .toolLengthOffset: return "Tool length offset"
            case .spindleOn: return "Spindle on"
            case .pause: return "Pause"
            case .dwell: return "Dwell"
            }
        }
    }

    static let base: Set<String> = ["SAFE_Z", "APPROACH_Z", "HOME_X", "HOME_Y", "HOME_Z", "JOB_NAME", "POST_NAME", "POST_VERSION",
                                    "SECONDS"]
    /// Which placeholders each template can use (`ProgramBuilder.render` and `GCodeWriter.dwell`); the editor shows them.
    public static let placeholders: [Template: Set<String>] = [
        .prelude: base, .preamble: base, .footer: base,
        .toolChange: base.union(["T", "TOOL_NAME", "S"]), .toolLengthOffset: base.union(["T", "TOOL_NAME", "S"]),
        .spindleOn: base.union(["T", "TOOL_NAME", "S"]),
        .pause: base.union(["MESSAGE", "STOP"]),
        .dwell: ["SECONDS", "MILLISECONDS", "DECIMAL_SECONDS"],
    ]
    /// User text: allowed only inside a comment on its line, where a tool name like "1/4 Z-2" cannot write a Z word.
    static let textPlaceholders: Set<String> = ["JOB_NAME", "POST_NAME", "POST_VERSION", "TOOL_NAME", "MESSAGE"]

    public static func make(_ draft: PostProfile) -> PostDraftReport {
        var r = PostDraftReport()
        r.problems = staticProblems(draft)
        guard r.problems.isEmpty else { return r }
        let plain = PostSampleJob.widened(draft)
        var plainDraft = plain
        plainDraft.toolChangeProbe = nil
        r.program = r.runSample(plainDraft, job: PostSampleJob.job(for: draft), label: "")
        if let controller = draft.controller {
            var probing = plain
            probing.toolChangeProbe = .on(ToolChangeProbe.defaults(controller: controller, units: plain.units, limits: plain.limits))
            r.probeProgram = r.runSample(probing, job: PostSampleJob.job(for: draft, probing: true),
                                         label: "With touch-plate tool changes: ")
        }
        return r
    }

    // MARK: Static rules

    static func staticProblems(_ p: PostProfile) -> [String] {
        var out: [String] = []
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("The post needs a name.") }
        if p.fileExtension.isEmpty || !p.fileExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            out.append("The file extension may hold only letters and digits.")
        }
        let templates: [(Template?, String, [String])] = templateLines(p).map { ($0.0, $0.0.label, $0.1) } + [
            (nil, "Spindle off", [p.spindleOff]), (nil, "Rapid", [p.rapid]), (nil, "Linear", [p.linear]),
            (nil, "Arc CW", [p.arcCW]), (nil, "Arc CCW", [p.arcCCW]),
        ]
        for (_, label, lines) in templates where lines.contains(where: { !$0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E } }) {
            out.append("\(label): use plain ASCII characters only (no curly quotes, dashes or control characters).")
        }
        do { _ = try PostProfile.fromJSON(p.toJSON()) } catch {
            out.append("The post would not load back: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        let range = p.units == .inch ? 3...6 : 2...6
        if !range.contains(p.decimals) {
            out.append("Decimals must be \(range.lowerBound) to \(range.upperBound) for \(p.units == .inch ? "an inch" : "a millimetre") post.")
        }
        if !(0...3).contains(p.feedDecimals) { out.append("Feed decimals must be 0 to 3.") }
        func positive(_ v: Double, _ name: String) { if !(v.isFinite && v > 0) { out.append("\(name) must be more than 0.") } }
        func nonNegative(_ v: Double, _ name: String) { if !(v.isFinite && v >= 0) { out.append("\(name) must be 0 or more.") } }
        positive(p.limits.xTravel, "X travel"); positive(p.limits.yTravel, "Y travel"); positive(p.limits.zTravel, "Z travel")
        positive(p.rapidRate, "Rapid rate"); positive(p.maxFeed, "Max feed")
        nonNegative(p.limits.maxSpoilboardCut, "Allowed spoilboard cut")
        nonNegative(p.minRPM, "Min RPM")
        if !(p.maxRPM.isFinite && p.maxRPM >= 1) { out.append("Max RPM must be at least 1.") }
        if p.minRPM > p.maxRPM { out.append("Min RPM is above max RPM.") }
        let halfDigit = 0.5 * pow(10, -Double(p.decimals))
        let maxTolerance = 0.01 * LengthUnit.inch.factor(to: p.units)
        if !(p.arcTolerance.isFinite && p.arcTolerance >= halfDigit - 1e-12 && p.arcTolerance <= maxTolerance + 1e-12) {
            out.append("Arc tolerance must be between half a digit (\(NumberFormat.compact(halfDigit, maxDecimals: 8))) and "
                       + "\(NumberFormat.compact(maxTolerance, maxDecimals: 4)) \(p.units.abbreviation).")
        }
        let noSpeed = BuiltInPosts.family(of: p.id).map(BuiltInPosts.noSpindleSpeedIDs.contains) ?? false
        let codes: [(String, String, String)] = [
            (p.rapid, #"^[Gg]0*0$"#, "Rapid must be G0"), (p.linear, #"^[Gg]0*1$"#, "Linear must be G1"),
            (p.arcCW, #"^[Gg]0*2$"#, "Arc CW must be G2"), (p.arcCCW, #"^[Gg]0*3$"#, "Arc CCW must be G3"),
            (p.spindleOff, #"^[Mm]0*5$"#, "Spindle off must be M5"),
            // A family whose controller takes its speed elsewhere (ShopBot's M3 is a switch, #106) may write M3 alone.
            (p.spindleOn, noSpeed ? #"^([Mm]0*3|[Mm]0*3 [Ss]\{S\}|[Ss]\{S\} [Mm]0*3)$"# : #"^([Mm]0*3 [Ss]\{S\}|[Ss]\{S\} [Mm]0*3)$"#,
             "Spindle on must be M3 S{S}"),
            (p.dwell, #"^([Gg]0*4 [Pp]\{(SECONDS|MILLISECONDS)\}|[Pp]\{(SECONDS|MILLISECONDS)\} [Gg]0*4|[Gg]0*4 [Xx]\{DECIMAL_SECONDS\}|[Xx]\{DECIMAL_SECONDS\} [Gg]0*4)$"#,
             "Dwell must be G4 P{SECONDS}, G4 P{MILLISECONDS} or G4 X{DECIMAL_SECONDS}"),
        ]
        for (value, pattern, message) in codes where value.range(of: pattern, options: .regularExpression) == nil {
            out.append("\(message) (found \"\(value)\").")
        }
        for (template, label, lines) in templates {
            guard let template else { continue }
            for line in lines { out += placeholderProblems(line, template: template, label: label, style: p.commentStyle) }
        }
        if let problem = p.dwellProblem { out.append(problem) }
        // Said here once; the sample would otherwise fail with the same message.
        if let problem = p.postProblem { out.append(problem) }
        if p.controller != nil, p.useToolLengthOffset {
            out.append("A post that declares a controller for touch-plate tool changes cannot use a tool length offset (G43).")
        }
        return out
    }

    /// The template lines a post writes, labelled for its problems: the editor and the build (`PostProfile.placeholderProblem`)
    /// scan the same ones. The pause is the one written (`pauseLines`, the default when the post has none).
    static func templateLines(_ p: PostProfile) -> [(Template, [String])] {
        [(.prelude, p.prelude ?? []), (.preamble, p.preamble), (.footer, p.footer), (.toolChange, p.toolChange),
         (.toolLengthOffset, [p.toolLengthOffset]), (.spindleOn, [p.spindleOn]), (.pause, p.pauseLines), (.dwell, [p.dwell])]
    }

    /// Every `{` opens an allowed `{NAME}` for the template, every `}` closes one; user text sits inside a comment, `{STOP}`
    /// outside one. A comment is what the post's controller reads as one (`GCodeParser.Comments`): `'` only for an apostrophe
    /// post, `( … )` and `;` for the others; a line break ends it, as the parser reads the written line.
    /// `unsafeOnly` (the build) keeps only user text outside a comment and `{STOP}` inside one: a stray brace or a name the
    /// template cannot use is written as typed, the post author's own text.
    static func placeholderProblems(_ line: String, template: Template, label: String,
                                    style: PostProfile.CommentStyle, unsafeOnly: Bool = false) -> [String] {
        var out: [String] = []
        let chars = Array(line)
        var i = 0, open = 0, semicolon = false
        while i < chars.count {
            let c = chars[i]
            if c == "\n" || c == "\r" || c == "\r\n" { open = 0; semicolon = false; i += 1; continue }
            // A `;` (or `'`) starts a comment only outside parentheses (as the parser reads it).
            if style == .apostrophe {
                if c == "'" { semicolon = true }
            } else if c == "(" { open += 1 } else if c == ")" { open = max(0, open - 1) } else if c == ";", open == 0 { semicolon = true }
            if c == "}" {
                if !unsafeOnly { out.append("\(label): a \"}\" that closes no placeholder in \"\(line)\".") }
                i += 1; continue
            }
            guard c == "{" else { i += 1; continue }
            var j = i + 1, name = ""
            while j < chars.count, chars[j].isASCII, chars[j].isUppercase || chars[j] == "_" { name.append(chars[j]); j += 1 }
            guard j < chars.count, chars[j] == "}", !name.isEmpty else {
                if !unsafeOnly { out.append("\(label): a \"{\" that is not a placeholder in \"\(line)\".") }
                i += 1; continue
            }
            let inComment = open > 0 || semicolon
            if !(placeholders[template] ?? []).contains(name) {
                if !unsafeOnly { out.append("\(label) cannot use {\(name)}.") }
            } else if textPlaceholders.contains(name), !inComment {
                out.append("\(label): {\(name)} is text and must be inside a comment, or it could write G-code words.")
            } else if name == "STOP", inComment {
                out.append("\(label): {STOP} inside a comment stops nothing.")
            }
            i = j + 1
        }
        return out
    }

    // MARK: The sample

    /// Posts `job` with `post`, validates it and checks its stops; returns the program (nil when it could not be posted).
    mutating func runSample(_ post: PostProfile, job: PostJob, label: String) -> String? {
        let text: String
        do {
            text = try TemplatePostProcessor(profile: post).post(job)
        } catch PostError.probe(let m) {
            problems.append(label + "The sample cannot be posted: \(m)"); return nil
        } catch {
            problems.append(label + "The sample cannot be posted: \(error)"); return nil
        }
        let validator = GCodeValidator(profile: post, job: job.job, units: job.units)
        let parsed = GCodeParser.parse(text, comments: post.parserComments)
        let found = validator.validate(toolpaths: job.toolpaths) + validator.validate(gcode: text)
        let noSpeed = BuiltInPosts.family(of: post.id).map(BuiltInPosts.noSpindleSpeedIDs.contains) ?? false
        for issue in found where !Self.isAllowedLift(issue, parsed: parsed) && !(noSpeed && Self.isNoSpeed(issue)) {
            issues.append(issue)
            problems.append(label + "The sample program: \(issue.description)")
        }
        problems += Self.stopProblems(text: text, parsed: parsed).map { label + $0 }
        return text
    }

    /// A family that sets no speed (`BuiltInPosts.noSpindleSpeedIDs`) starts the spindle with M3 alone, which the validator
    /// rightly warns about at every export; its sample may carry that warning.
    static func isNoSpeed(_ issue: GCodeIssue) -> Bool {
        issue.severity == .warning && issue.message.hasPrefix("Spindle started (M3/M4) with no speed")
    }

    /// The one warning a sample may carry: a coordinate shift on a block that is exactly `G53 G0 Z0` (a lift to the top of
    /// travel in a footer).
    static func isAllowedLift(_ issue: GCodeIssue, parsed: GCodeParser.Result) -> Bool {
        guard issue.severity == .warning, issue.message.contains("changes the coordinate system"), let line = issue.line,
              let b = parsed.blocks.first(where: { $0.line == line }) else { return false }
        let words = b.words.filter { $0.letter != "N" }
        return words.count == 3 && b.has("G", 53) && b.has("G", 0) && b.value("Z") == 0
    }

    /// Each tool change stops (`M0`) or selects that tool (`T<n>` then `M6`), and every `T` in it names that tool; the pause
    /// stops with `M0` before the next X/Y or feed move. Checked in the parsed program: template text cannot show it.
    static func stopProblems(text: String, parsed: GCodeParser.Result) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func line(containing s: String) -> Int? { lines.firstIndex { $0.contains(s) }.map { $0 + 1 } }
        let n = PostSampleJob.names
        guard let aLine = line(containing: "Toolpath: \(n.a) ["), let bLine = line(containing: "Toolpath: \(n.b) ["),
              let cLine = line(containing: "Toolpath: \(n.c) ["), let pauseLine = line(containing: "Pause after toolpath: \(n.a)")
        else { return ["The sample program is missing its toolpath comments; check the comment style."] }
        var out: [String] = []
        func isCut(_ b: GCodeBlock) -> Bool {
            b.values("G").contains { [1, 2, 3].contains($0) } && (b.value("X") != nil || b.value("Y") != nil || b.value("Z") != nil)
        }
        let lastCutOfB = parsed.blocks.filter { $0.line > bLine && $0.line < cLine && isCut($0) }.last?.line ?? bLine
        // A modal G1 can make a cut without a G word; the builder states the motion word after any template line, so the
        // first cut of a toolpath always carries it.
        func changeIsSafe(from start: Int, to end: Int, tool: Int) -> Bool {
            let window = parsed.blocks.filter { $0.line > start && $0.line < end }
            // Compared as numbers: a typed T word can be huge or fractional, which no Int conversion may see.
            let n = Double(tool)
            if window.contains(where: { $0.values("T").contains { $0 != n } }) { return false }
            if window.contains(where: { $0.has("M", 0) }) { return true }
            guard let t = window.firstIndex(where: { $0.values("T").contains { $0 == n } }) else { return false }
            return window[t...].contains { $0.has("M", 6) }
        }
        if !changeIsSafe(from: 0, to: aLine, tool: PostSampleJob.tool1.number) {
            out.append("The tool change before the first tool neither stops (M0) nor selects that tool (T\(PostSampleJob.tool1.number) then M6).")
        }
        if !changeIsSafe(from: lastCutOfB, to: cLine, tool: PostSampleJob.tool2.number) {
            out.append("The tool change between the tools neither stops (M0) nor selects the new tool (T\(PostSampleJob.tool2.number) then M6): "
                       + "the second tool's paths would be cut with the first bit.")
        }
        let afterPause = parsed.blocks.filter { $0.line > pauseLine && $0.line < bLine }
        let firstMove = afterPause.firstIndex { b in
            b.value("X") != nil || b.value("Y") != nil || b.values("G").contains { [1, 2, 3].contains($0) }
        } ?? afterPause.endIndex
        if !afterPause[..<firstMove].contains(where: { $0.has("M", 0) }) {
            out.append("The pause does not stop (no M0 before the next move): check that the pause lines contain {STOP} outside a comment.")
        }
        _ = isCut
        return out
    }
}
