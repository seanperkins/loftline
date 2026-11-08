import CADCore
import CAMCore
import Foundation

/// Short explanatory lines shown under toolpath forms.
public enum OperationHints {
    /// "3 pecks per hole: 0.125, 0.25, 0.375" style summary.
    public static func peckSummary(_ p: DrillParameters, units: LengthUnit) -> String {
        guard p.cutDepth > p.startDepth else { return "Cut depth must be deeper than the start depth." }
        let depths = DrillOperation.peckDepths(start: p.startDepth, end: p.cutDepth, peck: p.peckDepth)
        if depths.count == 1 { return "Single plunge to \(RulerTicks.label(p.cutDepth)) \(units.abbreviation)." }
        let list = depths.map { RulerTicks.label(($0 * 1000).rounded() / 1000) }.joined(separator: ", ")
        return "\(depths.count) pecks per hole: \(list) \(units.abbreviation)."
    }

    /// Why a cut from `startDepth` to `cutDepth` (document units) is deeper than `tool` can reach:
    /// its flutes are shorter, so the shank would rub the wall. Nil when the tool is unknown, has
    /// no flute length recorded, or reaches. `tool` is in document units. A preview of the
    /// toolpath's own warning, which also sees projection and array copies.
    public static func fluteLengthProblem(tool: Tool?, cutDepth: Double, startDepth: Double, units: LengthUnit) -> String? {
        guard let tool, let flute = tool.fluteLength, flute > 0 else { return nil }
        guard cutDepth - max(0, startDepth) > flute + CAMContext.defaultTolerance(units) else { return nil }
        return "Deeper than the \(Toolpath.FluteOverrun.text(flute, units: units)) \(units.abbreviation) flutes of \(tool.name); "
            + "the shank will rub the wall above them."
    }

    /// One message per clearance tool (nil = it will be used): each must be larger than the finish
    /// tool and smaller than the clearance tool before it.
    public static func pocketClearanceProblems(finish: Tool?, clearance: [Tool?]) -> [String?] {
        func inch(_ t: Tool) -> Double { t.diameter * t.units.factor(to: .inch) }
        var previous: Tool?
        return clearance.map { c in
            guard let c else { return "This tool is not in the tool database." }
            if let p = previous, inch(c) >= inch(p) - 1e-9 {
                return "Must be smaller than the clearance tool above it; it will be ignored."
            }
            if let problem = pocketClearanceProblem(finish: finish, clearance: c) { return problem }
            previous = c
            return nil
        }
    }

    /// Why a pocket's clearance tool would be ignored (nil when it will be used or none is set).
    public static func pocketClearanceProblem(finish: Tool?, clearance: Tool?) -> String? {
        guard let c = clearance else { return nil }
        guard let f = finish else { return "Choose a finish tool." }
        if c.id == f.id { return "The clearance tool is the finish tool; it will be ignored." }
        if c.diameter * c.units.factor(to: .inch) <= f.diameter * f.units.factor(to: .inch) + 1e-9 { return "The clearance tool must be larger than the finish tool; it will be ignored." }
        return nil
    }
}
