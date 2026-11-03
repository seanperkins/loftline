import Foundation

/// A post of a built-in family (a copy, or a file or project copy that carries the built-in's id) whose program writes a G or M
/// code the built-in's program for the same job does not (#99 item 14). The built-in's own words are the ones its controller is
/// known to read; what a controller does with a word it does not know differs (Centroid cancels the job, MASSO skips the line,
/// UCCNC follows a setting), so the warning names the codes and that behaviour. Compared on written programs, so every word the
/// builder writes counts (coolant, units, G90.1, rendered stops, the tool length line, a probed tool change).
public enum UnknownWords {
    static let consequences: [String: String] = [
        BuiltInPosts.massoG3Inch.id: "MASSO skips a whole line with a word it does not know.",
        BuiltInPosts.massoG3MM.id: "MASSO skips a whole line with a word it does not know.",
        BuiltInPosts.centroidInch.id: "CNC12 cancels the job at a word it does not know (error 502).",
        BuiltInPosts.centroidMM.id: "CNC12 cancels the job at a word it does not know (error 502).",
        BuiltInPosts.uccncInch.id: "UCCNC may run past, skip or stop at a code it does not know, as its settings say.",
        BuiltInPosts.uccncMM.id: "UCCNC may run past, skip or stop at a code it does not know, as its settings say.",
    ]
    static let general = "A controller may ignore, skip or refuse a word it does not know."
    public static func issues(text: String, job: PostJob, profile: PostProfile) -> [GCodeIssue] {
        guard let family = BuiltInPosts.family(of: profile.id), let builtIn = BuiltInPosts.profile(id: family) else { return [] }
        // The built-in with what a machine applies (MachineDefinition.applied(to:)), the post's units (so its units word is the
        // family's form in the post's units) and its number precision (a probe feed may need it): only the dialect differs.
        // A built-in that cannot probe is posted without the probe; if it still cannot post the job, stay silent.
        var reference = builtIn
        reference.decimals = profile.decimals
        reference.feedDecimals = profile.feedDecimals
        reference.units = profile.units
        reference.limits = profile.limits
        reference.rapidRate = profile.rapidRate
        reference.maxFeed = profile.maxFeed
        reference.minRPM = profile.minRPM
        reference.maxRPM = profile.maxRPM
        reference.toolChangeProbe = profile.toolChangeProbe
        // A built-in with only a machine's settings applied is its own reference: nothing to compare, no second post.
        var plain = profile
        plain.name = reference.name; plain.id = reference.id
        if plain == reference { return [] }
        var referenceText = try? TemplatePostProcessor(profile: reference).post(job)
        if referenceText == nil {
            reference.toolChangeProbe = nil
            referenceText = try? TemplatePostProcessor(profile: reference).post(job)
        }
        guard let referenceText else { return [] }

        let known = Set(words(referenceText, comments: reference.parserComments))
        var extra: [Word] = []
        for w in words(text, comments: profile.parserComments) where !known.contains(w) && !extra.contains(w) {
            extra.append(w)
        }
        guard !extra.isEmpty else { return [] }
        let codes = extra.map { "\($0.letter)\(NumberFormat.compact($0.value, maxDecimals: 3))" }.joined(separator: ", ")
        let consequence = consequences[family] ?? general
        return [GCodeIssue(severity: .warning, message: "\(profile.name) writes \(codes), which the built-in \(builtIn.name) post "
                                                       + "does not: \(consequence) Check that your controller reads them.")]
    }

    struct Word: Hashable { var letter: Character; var value: Double }

    /// The G and M codes of a program in order, without codes the validator does not model (it warns of those itself:
    /// `unknown-g`, `unknown-m`).
    static func words(_ text: String, comments: GCodeParser.Comments) -> [Word] {
        GCodeParser.parse(text, comments: comments).blocks.flatMap(\.words).compactMap { w in
            switch w.letter {
            case "G" where GCodeValidator.knownG.contains(w.value): return Word(letter: "G", value: w.value)
            case "M" where GCodeValidator.knownM.contains(w.value): return Word(letter: "M", value: w.value)
            default: return nil
            }
        }
    }
}
