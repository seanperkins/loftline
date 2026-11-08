import CADCore
import CAMCore
import Foundation

/// Expressions typed into numeric fields, waiting to be tied to the parameter they changed.
/// The field's parse strategy notes each expression that uses a variable, with the form it was typed in (its
/// `target`: one toolpath, or one sheet's job); the next project change links the one parameter of that target that
/// took the value (`VariableLinks.reconcile`). A field outside such a form notes nothing.
public final class ExpressionRecorder {
    public init() {}
    /// An expression and the value it gave, in `units` (nil for a unitless field), so the value
    /// can be matched after a unit change (Job Setup lets the units change after the typing).
    public struct Entry: Equatable { var text: String; var value: Double; var units: LengthUnit?; var target: VariableLink.Target }
    public private(set) var pending: [Entry] = []
    /// The last noted value, until the field writes it (see `nudge`).
    private var unwritten: Double?

    public func note(_ text: String, value: Double, units: LengthUnit?, target: VariableLink.Target?) {
        guard let target, VariableLink.usesVariables(text, units: units) else { return }
        pending.append(Entry(text: text.trimmingCharacters(in: .whitespaces), value: value, units: units, target: target))
        if pending.count > 32 { pending.removeFirst() }
        unwritten = value
    }

    /// When an expression evaluates to the value the field already holds, the field writes the
    /// next representable number instead, so the change (and so the parameter) can be found;
    /// linking then restores the exact value.
    public func valueToWrite(_ new: Double, current: Double) -> Double {
        defer { unwritten = nil }
        guard let u = unwritten, u == new, new == current else { return new }
        return new.nextUp
    }

    public func take() -> [Entry] {
        defer { pending = [] }
        return pending
    }
}

/// Links between numeric parameters (job setup, toolpath settings) and the expressions typed
/// into them. Parameters are found by diffing their JSON encoding, so every numeric field of
/// every form takes part without the forms knowing about links.
public enum VariableLinks {
    /// Updates `p.document.variableLinks` after an edit from `old` to `p`: parameters changed by
    /// hand lose their link, parameters that took a pending expression's value gain one, links
    /// of deleted toolpaths/sheets are dropped, and every link is re-evaluated (variables or the
    /// material may have changed). Returns links that could not be evaluated.
    @discardableResult
    public static func reconcile(_ p: inout LoftLineProject, old: LoftLineProject, pending: [ExpressionRecorder.Entry]) -> [VariableLink] {
        var links = p.document.linkedValues
        guard !links.isEmpty || !pending.isEmpty else { return [] }
        // After a unit change every leaf is rescaled; compared with the old project converted the
        // same way (the same factor through the same scaling code, so untouched leaves are equal
        // to the bit and a field nudged by one ulp still reads as changed), only the leaves the
        // edit touched differ, so an expression typed in the new units finds its value without a
        // coincidence elsewhere. Links that already existed are still dropped: their literals
        // ("=thickness - 0.1") were written in the old units.
        let unitsChanged = p.document.units != old.document.units
        let old = unitsChanged ? old.converted(to: p.document.units) : old
        let sheetIDs = Set(p.document.allSheets.map(\.id))
        let opIDs = Set(p.operations.map(\.id))
        links.removeAll {
            switch $0.target {
            case .job(let s): return !sheetIDs.contains(s)
            case .operation(let id): return !opIDs.contains(id)
            }
        }
        // One link per field, the last: links that disagree about one field (a crafted or damaged file) would flip it
        // on every pass and never settle.
        var seenFields = Set<String>()
        links = links.reversed().filter { seenFields.insert("\($0.target)|\($0.path)").inserted }.reversed()
        // Job fields linked in a cycle (`=thickness/2` typed into Thickness; Safe Z from the
        // thickness and the thickness from Safe Z) would move every time the links are re-evaluated;
        // such links are never made and never kept.
        links = withoutCycles(links, in: p)
        let targets = Set(links.map(\.target)).union(pending.map(\.target))
        for t in targets {
            guard let newTree = tree(of: t, in: p) else { continue }
            let oldTree = tree(of: t, in: old)
            // Hand edits (and unit conversion, whose literals no longer match) unlink.
            links.removeAll { l in
                guard l.target == t else { return false }
                if unitsChanged { return true }
                guard let o = oldTree else { return false }
                // A linked leaf is unlinked by any hand edit, however small. The form converts untouched
                // fields from the saved values in one step, so nothing here drifts by an ulp.
                return number(at: l.path, in: o) != number(at: l.path, in: newTree)
            }
            let typed = pending.filter { $0.target == t }
            guard !typed.isEmpty else { continue }
            var newLeaves: [[String]: Double] = [:]
            leaves(newTree, prefix: [], into: &newLeaves)
            let changed = newLeaves.filter { path, v in oldTree.map { number(at: path, in: $0) != v } ?? true }
            // In typing order: of two fields that would feed each other, the first one typed keeps its link.
            for e in typed {
                // A value typed in other units than the project now has (the form's units were
                // switched after the typing) is matched after the same conversion.
                let value = e.units.map { $0 != p.document.units ? e.value * $0.factor(to: p.document.units) : e.value } ?? e.value
                let candidates = changed.filter { abs(value - $0.value) <= 1e-9 * max(1, abs(value)) }
                // Exactly one field of the form took the value: that is the field it was typed into. Two (or none) say
                // nothing certain, so nothing is linked and the value stands.
                guard candidates.count == 1, let (path, v) = candidates.first,
                      !links.contains(where: { $0.target == t && $0.path == path && $0.expression == e.text }) else { continue }
                let link = VariableLink(target: t, path: path, expression: e.text)
                // The link must give back the value the field shows: a bare literal typed before
                // a unit switch ("=width/2 - 1" in inches) means something else in millimetres,
                // so that expression is not linked and the converted value stands.
                guard let check = evaluate(link, in: p), abs(check - v) <= 1e-9 * max(1, abs(v)) else { continue }
                let others = links.filter { !($0.target == t && $0.path == path) }
                guard !closesCycle(link, among: others, in: p) else { continue }
                links = others + [link]
            }
        }
        p.document.linkedValues = links
        return apply(&p)
    }

    /// Re-evaluates every link and writes the results, pass after pass until nothing changes, so a chain of links (a
    /// linked thickness feeding a linked width feeding a toolpath) settles in one edit whatever order the links are
    /// stored in. Cycles are never kept (`withoutCycles`), so `count + 1` passes suffice, capped at `maxPasses` so a
    /// crafted file cannot make one edit run for minutes. Returns links that failed.
    public static let maxPasses = 32

    @discardableResult
    public static func apply(_ p: inout LoftLineProject) -> [VariableLink] {
        var failed: [VariableLink] = []
        for _ in 0..<min(p.document.linkedValues.count + 1, maxPasses) {
            failed = []
            var changed = false
            for l in p.document.linkedValues {
                guard let value = evaluate(l, in: p) else { failed.append(l); continue }
                guard let t = tree(of: l.target, in: p), let cur = number(at: l.path, in: t) else {
                    failed.append(l); continue
                }
                if cur == value { continue }
                guard let updated = setting(value, at: l.path, in: t), write(updated, to: l.target, in: &p) else {
                    failed.append(l); continue
                }
                changed = true
            }
            if !changed { break }
        }
        return failed
    }

    /// The job fields an expression can name.
    public static let jobFields = ["width", "height", "thickness", "safez"]

    /// The job fields (lower-cased) a job link's expression uses on its own sheet. A user variable
    /// that shares a field's name counts as the field here, which errs towards refusing a link.
    public static func jobFieldsUsed(by l: VariableLink, in p: LoftLineProject) -> Set<String> {
        guard case .job(let sheet) = l.target else { return [] }
        let table = p.document.variableTable(forSheet: sheet)
        return Set(jobFields.filter { VariableLink.references($0, in: l.expression, variables: table, units: p.document.units) })
    }

    /// True when `link` on a job field, with the other job links of its sheet, leads back to its
    /// own field: `=thickness/2` in Thickness, or Safe Z from the thickness and the thickness from
    /// Safe Z. Followed through the job links only; operation links cannot feed a job field.
    public static func closesCycle(_ link: VariableLink, among links: [VariableLink], in p: LoftLineProject) -> Bool {
        guard case .job(let sheet) = link.target, let field = link.path.last?.lowercased() else { return false }
        var uses: [String: Set<String>] = [:]
        for l in links + [link] {
            guard case .job(let s) = l.target, s == sheet, let f = l.path.last?.lowercased() else { continue }
            uses[f] = jobFieldsUsed(by: l, in: p)
        }
        var seen: Set<String> = []
        var stack = Array(uses[field] ?? [])
        while let f = stack.popLast() {
            if f == field { return true }
            guard seen.insert(f).inserted else { continue }
            stack += uses[f] ?? []
        }
        return false
    }

    /// `links` without the job links that are part of a cycle.
    public static func withoutCycles(_ links: [VariableLink], in p: LoftLineProject) -> [VariableLink] {
        links.filter { l in
            guard case .job = l.target else { return true }
            return !closesCycle(l, among: links.filter { $0 != l }, in: p)
        }
    }

    public static func evaluate(_ l: VariableLink, in p: LoftLineProject) -> Double? {
        let sheet: UUID
        switch l.target {
        case .job(let s): sheet = s
        case .operation(let id):
            guard let op = p.operations.first(where: { $0.id == id }) else { return nil }
            sheet = p.sheetID(of: op) ?? p.document.currentSheetID
        }
        return try? ExpressionEvaluator.evaluate(l.expression, variables: p.document.variableTable(forSheet: sheet),
                                                 units: p.document.units)
    }

    /// "Profile 1 › Cut depth" style label for the variables sheet.
    public static func describe(_ l: VariableLink, in p: LoftLineProject) -> String {
        let owner: String
        switch l.target {
        case .job(let s):
            owner = p.document.isMultiSheet
                ? "Job Setup (\(p.document.allSheets.first { $0.id == s }?.name ?? "sheet"))" : "Job Setup"
        case .operation(let id): owner = p.operations.first { $0.id == id }?.setup.name ?? "Toolpath"
        }
        let parts = l.path.filter { $0 != "_0" && Int($0) == nil }.suffix(2).map(humanize)
        return ([owner] + parts).joined(separator: " › ")
    }

    public static func humanize(_ key: String) -> String {
        var out = ""
        for c in key {
            if c.isUppercase, !out.isEmpty { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    // MARK: JSON trees

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    public static func tree<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func decode<T: Decodable>(_ type: T.Type, from tree: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: tree, options: [.fragmentsAllowed]) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public static func tree(of t: VariableLink.Target, in p: LoftLineProject) -> Any? {
        switch t {
        case .job(let s): return p.document.job(ofSheet: s).flatMap { tree($0) }
        case .operation(let id): return p.operations.first { $0.id == id }.flatMap { tree($0) }
        }
    }

    public static func write(_ tree: Any, to t: VariableLink.Target, in p: inout LoftLineProject) -> Bool {
        switch t {
        case .job(let s):
            guard let job = decode(JobSetup.self, from: tree) else { return false }
            if s == p.document.currentSheetID {
                p.document.job = job
            } else if let i = p.document.otherSheets?.firstIndex(where: { $0.id == s }) {
                p.document.otherSheets![i].job = job
            } else { return false }
        case .operation(let id):
            guard let op = decode(AnyOperation.self, from: tree), op.id == id,
                  let i = p.operations.firstIndex(where: { $0.id == id }) else { return false }
            p.operations[i] = op
        }
        return true
    }

    public static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation stores a JSON true or false as a char or a Bool; parsed numbers are never a char.
        let type = n.objCType.pointee
        return type == CChar(UInt8(ascii: "c")) || type == CChar(UInt8(ascii: "B"))
        #endif
    }

    /// Numeric (non-boolean) leaves by path.
    public static func leaves(_ node: Any, prefix: [String], into out: inout [[String]: Double]) {
        if let d = node as? [String: Any] {
            for (k, v) in d { leaves(v, prefix: prefix + [k], into: &out) }
        } else if let a = node as? [Any] {
            for (i, v) in a.enumerated() { leaves(v, prefix: prefix + [String(i)], into: &out) }
        } else if let n = node as? NSNumber, !isBool(n) {
            out[prefix] = n.doubleValue
        }
    }

    public static func number(at path: [String], in node: Any) -> Double? {
        var cur: Any = node
        for k in path {
            if let d = cur as? [String: Any], let next = d[k] {
                cur = next
            } else if let a = cur as? [Any], let i = Int(k), a.indices.contains(i) {
                cur = a[i]
            } else { return nil }
        }
        guard let n = cur as? NSNumber, !isBool(n) else { return nil }
        return n.doubleValue
    }

    public static func setting(_ value: Double, at path: [String], in node: Any) -> Any? {
        guard let k = path.first else { return NSNumber(value: value) }
        let rest = Array(path.dropFirst())
        if var d = node as? [String: Any], let child = d[k] {
            guard let updated = setting(value, at: rest, in: child) else { return nil }
            d[k] = updated
            return d
        }
        if var a = node as? [Any], let i = Int(k), a.indices.contains(i) {
            guard let updated = setting(value, at: rest, in: a[i]) else { return nil }
            a[i] = updated
            return a
        }
        return nil
    }
}
