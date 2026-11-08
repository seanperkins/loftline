import CADCore
import Foundation
import LoftLineKit

/// One input a gadget asks for before it runs, declared in the script header:
///
///     // @param rows integer 3 "Rows"
///     // @param spacing length 1.5 "Spacing"      (default in inches; scaled for mm jobs)
///     // @param side choice outside|inside|on "Side"
///     // @param label text "LoftLine" "Label"
///     // @param drill bool true "Add a drilling toolpath"
struct GadgetParameter: Hashable, Identifiable {
    enum Kind: Hashable {
        case number, length, integer, bool, text
        case choice([String])
    }

    var name: String
    var kind: Kind
    /// Default as written in the header (lengths in inches).
    var defaultText: String
    var label: String

    var id: String { name }

    /// Default value for a document in `units` (lengths are written in inches).
    func defaultValue(units: LengthUnit) -> GadgetValue {
        switch kind {
        case .number: return .number(Double(defaultText) ?? 0)
        case .length: return .number((Double(defaultText) ?? 0) * LengthUnit.inch.factor(to: units))
        case .integer: return .number(Double(Int(Double(defaultText) ?? 0)))
        case .bool: return .bool(["true", "yes", "1", "on"].contains(defaultText.lowercased()))
        case .text: return .text(defaultText)
        case .choice(let options): return .text(options.contains(defaultText) ? defaultText : options.first ?? "")
        }
    }
}

/// A value passed to a gadget (`loftline.params.<name>` in the script).
enum GadgetValue: Hashable {
    case number(Double)
    case bool(Bool)
    case text(String)

    var number: Double? { if case .number(let v) = self { return v } else { return nil } }
    var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var text: String? { if case .text(let v) = self { return v } else { return nil } }

    var jsValue: Any {
        switch self {
        case .number(let v): return v
        case .bool(let v): return v
        case .text(let v): return v
        }
    }
}

/// A gadget: a JavaScript add-on that draws vectors and/or sets up toolpaths through the
/// `loftline` API (see `GadgetAPI.reference`). Metadata lives in the leading `//` comment block.
struct GadgetScript: Hashable, Identifiable {
    enum Origin: Hashable {
        case builtIn
        case file(URL)
    }

    var name: String
    var summary: String
    var parameters: [GadgetParameter]
    var source: String
    var origin: Origin
    /// Whether the gadget needs a selection to do anything (`// @needs-selection`).
    var needsSelection: Bool

    var id: String {
        switch origin {
        case .builtIn: return "builtin:" + name
        case .file(let url): return url.standardizedFileURL.path
        }
    }

    func defaultValues(units: LengthUnit) -> [String: GadgetValue] {
        Dictionary(parameters.map { ($0.name, $0.defaultValue(units: units)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Reads the header tags. Unknown tags are ignored; malformed `@param` lines are reported
    /// in `problems` and skipped so a typo never stops the gadget from loading.
    static func parse(source: String, fallbackName: String, origin: Origin) -> (script: GadgetScript, problems: [String]) {
        var name = fallbackName
        var summary: [String] = []
        var params: [GadgetParameter] = []
        var problems: [String] = []
        var needsSelection = false
        var seen = Set<String>()
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard line.hasPrefix("//") else { break }  // header = leading comment block
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let tokens = tokenize(String(body.dropFirst()))
            guard let tag = tokens.first?.lowercased() else { continue }
            let rest = Array(tokens.dropFirst())
            switch tag {
            case "name":
                if !rest.isEmpty { name = rest.joined(separator: " ") }
            case "description":
                summary.append(rest.joined(separator: " "))
            case "needs-selection":
                needsSelection = true
            case "param":
                switch parseParam(rest) {
                case .success(let p):
                    if seen.insert(p.name).inserted { params.append(p) } else { problems.append("Parameter \"\(p.name)\" is declared twice.") }
                case .failure(let e):
                    problems.append(e.message)
                }
            default:
                continue
            }
        }
        let script = GadgetScript(name: name, summary: summary.joined(separator: " "), parameters: params,
                                  source: source, origin: origin, needsSelection: needsSelection)
        return (script, problems)
    }

    private struct ParamError: Error { var message: String }

    private static func parseParam(_ t: [String]) -> Result<GadgetParameter, ParamError> {
        guard t.count >= 3 else {
            return .failure(ParamError(message: "@param needs a name, a type and a default: \(t.joined(separator: " "))"))
        }
        let name = t[0]
        guard DocumentVariable.isValidName(name) else {
            return .failure(ParamError(message: "\"\(name)\" is not a valid parameter name (letters, digits, _)."))
        }
        let label = t.count >= 4 ? t[3...].joined(separator: " ") : name
        let type = t[1].lowercased()
        var dflt = t[2]
        let kind: GadgetParameter.Kind
        switch type {
        case "number": kind = .number
        case "length": kind = .length
        case "integer", "int": kind = .integer
        case "bool", "boolean": kind = .bool
        case "text", "string": kind = .text
        default:
            if type.hasPrefix("choice") {
                // "choice a|b|c" with the first option the default, or "choice:a|b|c <default>".
                let list: String
                if type.hasPrefix("choice:") {
                    list = String(t[1].dropFirst("choice:".count))
                } else {
                    list = t[2]
                    dflt = t[2].split(separator: "|").first.map(String.init) ?? ""
                }
                let options = list.split(separator: "|").map(String.init).filter { !$0.isEmpty }
                guard !options.isEmpty else { return .failure(ParamError(message: "Choice \"\(name)\" has no options.")) }
                kind = .choice(options)
            } else {
                return .failure(ParamError(message: "Unknown parameter type \"\(t[1])\" for \"\(name)\"."))
            }
        }
        switch kind {
        case .number, .length, .integer:
            guard Double(dflt) != nil else {
                return .failure(ParamError(message: "Default \"\(dflt)\" of \"\(name)\" is not a number."))
            }
        default: break
        }
        return .success(GadgetParameter(name: name, kind: kind, defaultText: dflt, label: label))
    }

    /// Splits on spaces; double quotes group words (no escapes).
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var hadQuotes = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); hadQuotes = true; continue }
            if ch.isWhitespace && !quoted {
                if !cur.isEmpty || hadQuotes { out.append(cur) }
                cur = ""; hadQuotes = false
                continue
            }
            cur.append(ch)
        }
        if !cur.isEmpty || hadQuotes { out.append(cur) }
        return out
    }
}
