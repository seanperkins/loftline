import CADCore
import CAMCore
import Foundation
import PostCore

/// Checks for mistakes the G-code validator cannot see, because the program is well formed and
/// the machine would run it exactly as written: a through cut with nothing holding the part, two
/// different tools sharing a number, a 3D model deeper than the material, a tool whose name says
/// one size and whose diameter is another. All are warnings shown with the export, never a modal
/// alert: each has a legitimate reading (tape or vacuum hold-down, a deliberate name), and the
/// person at the machine decides.
enum PreflightChecks {
    /// Every check for a combined program: `toolpaths` are the ones being exported.
    static func issues(project: LoftLineProject, toolpaths: [Toolpath], units: LengthUnit) -> [GCodeIssue] {
        let exported = Set(toolpaths.compactMap(\.operationID))
        let operations = project.operations.filter { exported.contains($0.id) }
        var tools: [Tool] = []
        for tp in toolpaths where !tools.contains(where: { $0.id == tp.tool.id }) { tools.append(tp.tool) }
        return looseParts(operations, document: project.document)
            + duplicateToolNumbers(tools)
            + toolNameMismatches(tools)
            + modelsDeeperThanStock(project.document)
    }

    // MARK: Loose parts

    /// Profile toolpaths that cut closed vectors through the full thickness with tabs off. The last
    /// pass frees the part while the cutter is still in it; the usual result is a thrown part and a
    /// broken bit, unless something else holds it.
    static func looseParts(_ operations: [AnyOperation], document doc: Document) -> [GCodeIssue] {
        let thickness = doc.job.thickness
        let tol = doc.units == .inch ? 0.0005 : 0.01
        var out: [GCodeIssue] = []
        for (name, p) in operations.flatMap(profiles) {
            guard !p.params.tabs.isEnabled, p.params.depth.cutDepth >= thickness - tol else { continue }
            let closed = doc.shapes(ids: p.setup.shapeIDs).filter { $0.paths.contains(where: \.isClosed) }
            guard !closed.isEmpty else { continue }
            let n = closed.count
            let what = n == 1 ? "1 closed vector" : "\(n) closed vectors"
            out.append(GCodeIssue(severity: .warning, message:
                "\(name) cuts \(what) through the full \(RulerTicks.label(thickness)) \(doc.units.abbreviation) with tabs off: "
                + "the part comes loose while the cutter is still in it. Turn on Tabs, or make sure the part is held another way."))
        }
        return out
    }

    /// The profiles an exported operation cuts, with the name to report: the operation itself, or
    /// the parts of a merged operation (the merge is what the toolpaths point at, but each part
    /// still makes its own cut with its own tabs and depth).
    static func profiles(in op: AnyOperation) -> [(name: String, profile: ProfileOperation)] {
        switch op {
        case .profile(let p): return [(op.setup.name, p)]
        case .merge(let m):
            return m.params.children.flatMap(profiles).map { ("\($0.name) (in \(op.setup.name))", $0.profile) }
        default: return []
        }
    }

    // MARK: Tool numbers

    /// Two different tools in one program with the same number but different geometry: the post
    /// writes the same T word for both, so the controller (and an operator reading T numbers) cannot
    /// tell them apart. Same number and same geometry is only a duplicate library entry, which is fine.
    static func duplicateToolNumbers(_ tools: [Tool]) -> [GCodeIssue] {
        var byNumber: [Int: [Tool]] = [:]
        for t in tools { byNumber[t.number, default: []].append(t) }
        var out: [GCodeIssue] = []
        for number in byNumber.keys.sorted() {
            let group = byNumber[number]!
            guard group.count > 1 else { continue }
            var distinct: [Tool] = []
            for t in group where !distinct.contains(where: { sameGeometry($0, t) }) { distinct.append(t) }
            guard distinct.count > 1 else { continue }
            let names = distinct.map { "\"\($0.name)\" (\(describe($0)))" }.joined(separator: " and ")
            out.append(GCodeIssue(severity: .warning, message:
                "T\(number) is \(distinct.count) different tools in this program: \(names). "
                + "The program says T\(number) for both, so give one of them another number in the tool database."))
        }
        return out
    }

    static func sameGeometry(_ a: Tool, _ b: Tool) -> Bool { a.hasSameGeometry(as: b) }

    private static func inches(_ v: Double, _ units: LengthUnit) -> Double { v * units.factor(to: .inch) }

    private static func describe(_ t: Tool) -> String {
        var s = "\(t.kind.displayName.lowercased()), \(RulerTicks.label(t.diameter)) \(t.units.abbreviation)"
        if let a = t.angle { s += ", \(RulerTicks.label(a))°" }
        return s
    }

    // MARK: Names

    /// A size written in the tool's name that no reading of it matches the diameter: the name is
    /// what the operator reads at the tool change, the diameter is what the offsets use. A name
    /// that gives no size, or several sizes one of which matches the diameter (or the tip diameter
    /// of a V-bit or engraving cutter, which is what their names usually quote), is left alone.
    static func toolNameMismatches(_ tools: [Tool]) -> [GCodeIssue] {
        tools.compactMap { t in
            let named = sizesInInches(inName: t.name)
            guard !named.isEmpty else { return nil }
            let actual = [t.diameter, t.tipDiameter].filter { $0 > 0 }.map { inches($0, t.units) }
            let matches = named.contains { n in actual.contains { abs(n - $0) <= max(0.002, $0 * 0.02) } }
            guard !matches else { return nil }
            return GCodeIssue(severity: .warning, message:
                "Tool T\(t.number) is named \"\(t.name)\" but its diameter is \(RulerTicks.label(t.diameter)) \(t.units.abbreviation): "
                + "the toolpaths are offset for \(RulerTicks.label(t.diameter)) \(t.units.abbreviation). Fix the name or the diameter in the tool database.")
        }
    }

    /// Every length written in a tool name, in inches: 1/4", 1/4 in, .25", 0.25in, 6mm, 3.175 mm, and mixed numbers
    /// (1-1/4", and 1 1/4 in as the tool library names its own tools).
    /// A bare fraction (1/4) is inches; a bare decimal is not a size (2 flute, 60 deg, #3).
    static func sizesInInches(inName name: String) -> [Double] {
        var sizes: [Double] = []
        let unit = #"(?:"|”|in\b|inch(?:es)?\b)"#
        func mixed(_ m: NSTextCheckingResult, _ s: String) -> Double? {
            guard let w = Double(group(m, 1, s)), let a = Double(group(m, 2, s)), let b = Double(group(m, 3, s)), b > 0
            else { return nil }
            return w + a / b
        }
        // Earlier patterns take precedence: text one of them read is not read again by a later one, so the fraction
        // inside "1-1/4" is not also a size of its own, while "1/8-1/4" still gives both of its fractions.
        let patterns: [(String, (NSTextCheckingResult, String) -> Double?)] = [
            // 1-1/4", 1-1/2 in: hyphenated, so the unit may be left out
            (#"(?<![\d./])(\d+)\s*-\s*(\d+)\s*/\s*(\d+)\s*"# + unit + "?", mixed),
            // 1 1/4 in: spaced, so the unit is required (and a tool number before the fraction is not a whole part)
            (#"(?<![\w#./-])(\d+)\s+(\d+)\s*/\s*(\d+)\s*"# + unit, mixed),
            // 1/4", 1/4 in, 1/4in, 1/4 inch, or a bare 1/4
            (#"(?<![\d.])(\d+)\s*/\s*(\d+)\s*"# + unit + "?", { m, s in
                guard let a = Double(group(m, 1, s)), let b = Double(group(m, 2, s)), b > 0 else { return nil }
                return a / b
            }),
            // 0.25", .25in, 0.5 inch
            (#"(?<![\d./])(\d*\.\d+|\d+)\s*"# + unit, { m, s in Double(group(m, 1, s)) }),
            // 6mm, 3.175 mm
            (#"(?<![\d./])(\d*\.\d+|\d+)\s*mm\b"#, { m, s in Double(group(m, 1, s)).map { $0 / 25.4 } }),
        ]
        let range = NSRange(name.startIndex..., in: name)
        var read: [NSRange] = []
        for (pattern, value) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: name, options: [], range: range)
            where !read.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                if let v = value(m, name), v > 0 { sizes.append(v); read.append(m.range) }
            }
        }
        return sizes
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }

    // MARK: Models

    /// A placed 3D model whose lowest point is below the material bottom: the 3D toolpaths that
    /// follow it would cut through the stock into the spoilboard.
    static func modelsDeeperThanStock(_ doc: Document) -> [GCodeIssue] {
        let tol = doc.units == .inch ? 0.0005 : 0.01
        let u = doc.units.abbreviation
        return doc.models.filter { $0.depth > doc.job.thickness + tol }.map { m in
            GCodeIssue(severity: .warning, message:
                "3D model \"\(m.name)\" reaches \(RulerTicks.label(m.depth)) \(u) below the material top, but the material is "
                + "\(RulerTicks.label(doc.job.thickness)) \(u) thick: its toolpaths cut through the bottom. "
                + "Use thicker material, or give the model less height in Place 3D Model….")
        }
    }
}
