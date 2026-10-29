import CAMCore
import Foundation

/// Built-in controllers' own limits, checked at export beside `ToolChangeZ`, by built-in family (`BuiltInPosts.family(of:)`), so
/// an edited or duplicated copy keeps them: coolant on a controller without it (#105, #114), MASSO's tool numbers and its lack
/// of G43 (#107), UCCNC's profile units (#108), Centroid's dwell range (#103) and T0 on Syntec and Haas (#110, #111).
public enum DialectChecks {
    public static let uccncUnitsWarningPrefix = "UCCNC takes units from its profile"
    static let massoIDs: Set<String> = [BuiltInPosts.massoG3Inch.id, BuiltInPosts.massoG3MM.id]
    static let uccncIDs: Set<String> = [BuiltInPosts.uccncInch.id, BuiltInPosts.uccncMM.id]
    static let centroidIDs: Set<String> = [BuiltInPosts.centroidInch.id, BuiltInPosts.centroidMM.id]
    /// CNC12's documented dwell range, seconds.
    static let centroidDwell = 0.01...327.67

    public static func issues(toolpaths: [Toolpath], profile: PostProfile) -> [GCodeIssue] {
        guard let family = BuiltInPosts.family(of: profile.id) else { return [] }
        // Only toolpaths that post: one with no moves is left out of the program (`ProgramBuilder`).
        let posting = toolpaths.filter { !$0.moves.isEmpty }
        var out: [GCodeIssue] = []
        func error(_ s: String) { out.append(GCodeIssue(severity: .error, message: s)) }
        func unique(_ names: [String]) -> String {
            var seen = Set<String>()
            return names.filter { seen.insert($0).inserted }.joined(separator: ", ")
        }

        if let reason = BuiltInPosts.noCoolantReasons[family] {
            let cooled = posting.filter { $0.coolant != nil }.map(\.name)
            if !cooled.isEmpty { error("\(reason): turn coolant off for \(unique(cooled)).") }
        }
        if massoIDs.contains(family) {
            // MASSO gives T0 to the dry-run laser and numbers past 100 to other heads.
            let wrong = posting.map(\.tool.number).filter { !(1...100).contains($0) }
            if !wrong.isEmpty {
                error("MASSO selects the main spindle's tools with T1 to T100 (T0 is the laser, higher numbers other heads): "
                      + "renumber \(unique(wrong.map { "T\($0)" })).")
            }
            if profile.useToolLengthOffset, BuiltInPosts.noToolLengthOffsetIDs.contains(family) {
                error("MASSO has no G43, and it skips a line with a word it does not know: turn Tool Length Offset off.")
            }
        }
        if BuiltInPosts.noToolZeroIDs.contains(family), posting.contains(where: { $0.tool.number == 0 }) {
            let names = posting.filter { $0.tool.number == 0 }.map(\.name)
            error("T0 selects no tool and G43 H0 applies no length offset on this controller: renumber T0 for \(unique(names)).")
        }
        if uccncIDs.contains(family) {
            let units = profile.units == .inch ? "inches" : "millimetres"
            out.append(GCodeIssue(severity: .warning, message: "\(uccncUnitsWarningPrefix) and may ignore G20/G21: set the profile to "
                                                              + "\(units) before running this program."))
        }
        if centroidIDs.contains(family) {
            let outside = posting.filter { tp in
                tp.moves.contains { if case .dwell(let s) = $0 { return s > 0 && !centroidDwell.contains(s) }; return false }
            }.map(\.name)
            let spinUp = profile.spindleDwellSeconds
            let names = outside + (spinUp > 0 && !centroidDwell.contains(spinUp) ? ["the spindle start (the post's dwell)"] : [])
            if !names.isEmpty {
                error("CNC12 documents dwells of 0.01 to 327.67 s: change the dwell of \(unique(names)).")
            }
        }
        return out
    }
}
