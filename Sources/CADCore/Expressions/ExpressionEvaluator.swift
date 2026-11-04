import Foundation

/// A named number the user can type into numeric fields (e.g. `=thickness / 2`).
public struct DocumentVariable: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var value: Double

    public init(id: UUID = UUID(), name: String, value: Double) {
        self.id = id; self.name = name; self.value = value
    }

    /// Letters, digits and "_", not starting with a digit.
    public static func isValidName(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, CharacterSet.letters.contains(f) || f == "_" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }
}

extension Document {
    /// User variables (stored optionally so older files decode unchanged).
    public var userVariables: [DocumentVariable] {
        get { variables ?? [] }
        set { variables = newValue.isEmpty ? nil : newValue }
    }

    /// Every name usable in expressions (lower-cased): the material's `width`, `height`,
    /// `thickness`, `safez`, then user variables (which may override them).
    public var variableTable: [String: Double] {
        var t: [String: Double] = ["width": job.width, "height": job.height, "thickness": job.thickness,
                                   "safez": job.safeZ]
        for v in userVariables { t[v.name.lowercased()] = v.value }
        return t
    }
}

/// Arithmetic for numeric fields: numbers, `+ - * / ^`, parentheses, unary minus, variable
/// names (case-insensitive) and optional unit suffixes (`in`, `"`, `mm`, `cm`) converted to the
/// document's units; a suffix applies to the product/quotient before it ("1/4in"). A leading
/// `=` is allowed ("=thickness-0.1").
public enum ExpressionEvaluator {
    public enum ExpressionError: Error, Equatable, Sendable {
        case syntax(String)
        case unknownVariable(String)
        case divisionByZero
    }

    public static func evaluate(_ text: String, variables: [String: Double] = [:],
                                units: LengthUnit? = nil) throws -> Double {
        var p = Parser(chars: Array(text.trimmingCharacters(in: .whitespaces)), variables: variables, units: units)
        if p.peek == "=" { p.i += 1 }
        let v = try p.expression()
        p.skipSpace()
        guard p.i == p.chars.count else { throw ExpressionError.syntax("unexpected '\(p.chars[p.i])'") }
        guard v.isFinite else { throw ExpressionError.syntax("result is not a number") }
        return v
    }

    struct Parser {
        let chars: [Character]
        let variables: [String: Double]
        let units: LengthUnit?
        var i = 0
        /// Nesting of parentheses and unary signs; pasted junk must not overflow the stack.
        var depth = 0
        static let maxDepth = 64   // five frames per level; must fit a 512 KB secondary-thread stack

        init(chars: [Character], variables: [String: Double], units: LengthUnit?) {
            self.chars = chars; self.variables = variables; self.units = units
        }

        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func skipSpace() { while let c = peek, c == " " || c == "\t" { i += 1 } }

        mutating func expression() throws -> Double {
            var v = try term()
            while true {
                skipSpace()
                if peek == "+" { i += 1; v += try term() } else if peek == "-" { i += 1; v -= try term() } else { return v }
            }
        }

        mutating func term() throws -> Double {
            var v = try unary()
            while true {
                // A unit applies to the product/quotient so far: "1/4in" is a quarter inch.
                v *= unitSuffix()
                skipSpace()
                if peek == "*" { i += 1; v *= try unary() } else if peek == "/" {
                    i += 1
                    let d = try unary()
                    guard d != 0 else { throw ExpressionError.divisionByZero }
                    v /= d
                } else { return v }
            }
        }

        /// Unary minus binds looser than "^": -2^2 = -4.
        mutating func unary() throws -> Double {
            skipSpace()
            if peek == "-" || peek == "+" {
                let negative = peek == "-"
                i += 1
                try descend()
                defer { depth -= 1 }
                let v = try unary()
                return negative ? -v : v
            }
            return try power()
        }

        mutating func descend() throws {
            depth += 1
            guard depth <= Self.maxDepth else { throw ExpressionError.syntax("expression nested too deeply") }
        }

        mutating func power() throws -> Double {
            let b = try primary()
            skipSpace()
            // Right-associative, so a chain recurses as deep as it is long: count each "^" against the cap.
            if peek == "^" {
                i += 1
                try descend()
                defer { depth -= 1 }
                return pow(b, try unary())
            }
            return b
        }

        mutating func primary() throws -> Double {
            skipSpace()
            guard let c = peek else { throw ExpressionError.syntax("missing value") }
            if c == "(" {
                i += 1
                try descend()
                defer { depth -= 1 }
                let v = try expression()
                skipSpace()
                guard peek == ")" else { throw ExpressionError.syntax("missing ')'") }
                i += 1
                return v
            }
            if c.isNumber || c == "." {
                let start = i
                while let d = peek, d.isNumber || d == "." { i += 1 }
                if let e = peek, e == "e" || e == "E", i + 1 < chars.count,
                   chars[i + 1].isNumber || chars[i + 1] == "-" || chars[i + 1] == "+" {
                    i += 2
                    while let d = peek, d.isNumber { i += 1 }
                }
                guard let v = Double(String(chars[start..<i])) else { throw ExpressionError.syntax("bad number") }
                return v
            }
            if c.isLetter || c == "_" {
                let start = i
                while let d = peek, d.isLetter || d.isNumber || d == "_" { i += 1 }
                let name = String(chars[start..<i]).lowercased()
                guard let v = variables[name] else { throw ExpressionError.unknownVariable(name) }
                return v
            }
            throw ExpressionError.syntax("unexpected '\(c)'")
        }

        /// Factor for a unit written right after a number (1 when none or no document units).
        mutating func unitSuffix() -> Double {
            skipSpace()
            func take(_ s: String) -> Bool {
                let cs = Array(s)
                guard i + cs.count <= chars.count, Array(chars[i..<(i + cs.count)]).map({ Character($0.lowercased()) }) == cs
                else { return false }
                // Must not run into an identifier ("2 inner" is not "2 in" + "ner").
                if i + cs.count < chars.count, chars[i + cs.count].isLetter { return false }
                i += cs.count
                return true
            }
            guard let units else { return 1 }
            if peek == "\"" { i += 1; return LengthUnit.inch.factor(to: units) }
            if take("in") { return LengthUnit.inch.factor(to: units) }
            if take("mm") { return LengthUnit.millimeter.factor(to: units) }
            if take("cm") { return LengthUnit.millimeter.factor(to: units) * 10 }
            return 1
        }
    }
}
