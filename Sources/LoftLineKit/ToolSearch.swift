import CADCore
import Foundation

/// The Tool Database's search box: which tools a query leaves in the list (issue #18).
///
/// A query is words; a tool stays when every word matches something about it. A word matches when it is
/// part of the name, the description (the tool's notes), the group, the type, the cutter shape or the name of
/// a material it has cutting data for; when it is the tool's number (`3` or `T3`, whole: `3` does not find T30);
/// when it is the bit's included angle (`60` or `60°`); or when it is the diameter: `0.25`, `1/4`, `.25in`,
/// `1/4"`, `6mm` (a number alone is read in the tool's own units, one with a unit is converted).
public enum ToolSearch {
    public static func matches(_ tool: Tool, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.allSatisfy { matches(tool, word: $0) }
    }

    public static func filter(_ tools: [Tool], query: String) -> [Tool] {
        tools.filter { matches($0, query: query) }
    }

    /// The tool's description: the first line of its notes, which is what the list and the pickers show.
    public static func description(of tool: Tool) -> String? {
        tool.notes.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// "T3 · 1/2" End Mill (2 flute) — roughing, upcut" for a picker: the description follows, cut at 40 characters.
    public static func pickerLabel(_ tool: Tool) -> String {
        let base = "T\(tool.number) · \(tool.name)"
        guard let d = description(of: tool) else { return base }
        return base + " — " + (d.count > 40 ? d.prefix(39) + "…" : d)
    }

    private static func matches(_ tool: Tool, word: String) -> Bool {
        if text(of: tool).contains(where: { contains($0, word) }) { return true }
        let lower = word.lowercased()
        // The number as a whole, with or without the T.
        if let n = Int(lower.hasPrefix("t") ? String(lower.dropFirst()) : lower), n == tool.number { return true }
        if let (value, unit) = length(word) {
            // The diameter, in the unit the word names (or the tool's own).
            let diameter = tool.diameter * tool.units.factor(to: unit ?? tool.units)
            if abs(diameter - value) <= 0.0005 * max(1, abs(value)) { return true }
            if let angle = tool.angle, unit == nil, abs(angle - value) < 1e-9 { return true }
        }
        if word.hasSuffix("°"), let a = Double(word.dropLast()), let angle = tool.angle, abs(angle - a) < 1e-9 { return true }
        return false
    }

    /// What a word can be part of.
    private static func text(of tool: Tool) -> [String] {
        var out = [tool.name, tool.notes, tool.kind.displayName, ToolGrouping.section(tool)]
        if let shape = tool.shape { out.append(shape.displayName) }
        if let group = tool.group { out.append(group) }
        out += (tool.materials ?? []).map(\.material)
        return out
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A length typed as a decimal or a fraction with an optional unit: `0.25`, `.25in`, `1/4"`, `6mm`.
    public static func length(_ word: String) -> (value: Double, unit: LengthUnit?)? {
        var w = word.lowercased()
        var unit: LengthUnit?
        for (suffix, u) in [("mm", LengthUnit.millimeter), ("in", .inch), ("\"", .inch), ("”", .inch)] where w.hasSuffix(suffix) {
            w.removeLast(suffix.count)
            unit = u
            break
        }
        let parts = w.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            guard let v = Double(parts[0]), v.isFinite else { return nil }
            return (v, unit)
        case 2:
            guard let n = Double(parts[0]), let d = Double(parts[1]), d != 0, n.isFinite, d.isFinite else { return nil }
            return (n / d, unit)
        default:
            return nil
        }
    }
}

/// A name for a tool from its geometry: "1/4 in 2-flute end mill", "60° V-bit 1/2 in" (issue #18).
public enum ToolNaming {
    public static func name(for tool: Tool) -> String {
        let size = length(tool.diameter, in: tool.units)
        let flutes = "\(max(tool.flutes, 1))-flute"
        switch tool.kind {
        case .endMill:
            switch tool.shape {
            case .bullNose?: return "\(size) \(flutes) bull nose end mill"
            case .form?: return "\(size) form tool"
            default: return "\(size) \(flutes) end mill"
            }
        case .ballNose:
            if case .taperedBallNose? = tool.shape { return "\(size) tapered ball nose" }
            return "\(size) \(flutes) ball nose"
        case .vBit:
            return "\(angle(tool.angle))V-bit \(size)"
        case .engraving:
            let tip = tool.tipDiameter > 0 ? " \(length(tool.tipDiameter, in: tool.units)) tip" : ""
            return "\(angle(tool.angle))engraving bit\(tip)"
        case .drill:
            return "\(size) drill"
        }
    }

    private static func angle(_ a: Double?) -> String {
        guard let a else { return "" }
        return trimmed(a, places: 1) + "° "
    }

    /// An inch size as the nearest 64th when it is one ("1/4 in", "1 3/8 in") and as a decimal otherwise ("0.01 in");
    /// a millimetre size as a decimal ("6 mm", "3.175 mm").
    public static func length(_ v: Double, in units: LengthUnit) -> String {
        guard units == .inch else { return trimmed(v, places: 3) + " mm" }
        let sixtyFourths = (v * 64).rounded()
        // (A size past a trillion 64ths is no fraction a person made; `Int` would trap on the huge ones.)
        if v > 0, sixtyFourths < 1e12, abs(v - sixtyFourths / 64) < 1e-4 {
            var n = Int(sixtyFourths), d = 64
            while n % 2 == 0, d > 1 { n /= 2; d /= 2 }
            let whole = n / d, rest = n % d
            switch (whole, rest) {
            case (_, 0): return "\(whole) in"
            case (0, _): return "\(rest)/\(d) in"
            default: return "\(whole) \(rest)/\(d) in"
            }
        }
        return trimmed(v, places: 4) + " in"
    }

    private static func trimmed(_ v: Double, places: Int) -> String {
        var s = String(format: "%.\(places)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
