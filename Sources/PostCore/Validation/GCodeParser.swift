import Foundation

/// One parsed G-code block (line): address words in order, comments removed.
public struct GCodeBlock: Hashable, Sendable {
    public struct Word: Hashable, Sendable {
        public var letter: Character
        public var value: Double
    }

    /// 1-based physical line number in the source text.
    public var line: Int
    public var words: [Word]

    public func values(_ letter: Character) -> [Double] { words.filter { $0.letter == letter }.map(\.value) }
    public func value(_ letter: Character) -> Double? { words.last { $0.letter == letter }?.value }
    public func has(_ letter: Character, _ code: Double) -> Bool {
        words.contains { $0.letter == letter && abs($0.value - code) < 1e-9 }
    }
}

/// Minimal RS-274 tokenizer: strips `( ... )` and `;` comments and `%` lines, and splits address words (letter + signed
/// decimal). Unparseable text is reported. A block-delete line (`/…`) is parsed like any other, since the controller runs it
/// whenever Block Delete is off (#120), and its line is listed in `blockDeleteLines`.
public enum GCodeParser {
    public struct Result: Sendable {
        public var blocks: [GCodeBlock]
        /// (line, text) of fragments that are not valid words.
        public var garbage: [(line: Int, text: String)]
        /// Lines that start with `/` (block delete): parsed as code, since they run when Block Delete is off.
        public var blockDeleteLines: [Int] = []
    }

    public static func parse(_ text: String) -> Result {
        var blocks: [GCodeBlock] = []
        var garbage: [(Int, String)] = []
        var blockDeleteLines: [Int] = []
        var lineNo = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNo += 1
            var body = ""
            var depth = 0
            for ch in raw {
                if ch == ";" && depth == 0 { break }
                if ch == "(" { depth += 1; continue }
                if ch == ")" { depth = max(0, depth - 1); continue }
                if depth == 0 { body.append(ch) }
            }
            var trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/") {
                blockDeleteLines.append(lineNo)
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.isEmpty || trimmed == "%" { continue }
            var words: [GCodeBlock.Word] = []
            let chars = Array(trimmed.uppercased())
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == " " || c == "\t" { i += 1; continue }
                guard c.isLetter else {
                    garbage.append((lineNo, String(c))); i += 1; continue
                }
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                var num = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "-" || chars[j] == "+" {
                    num.append(chars[j]); j += 1
                }
                if let v = Double(num) {
                    words.append(.init(letter: c, value: v))
                } else {
                    garbage.append((lineNo, String(c) + num))
                }
                i = j
            }
            if !words.isEmpty { blocks.append(GCodeBlock(line: lineNo, words: words)) }
        }
        return Result(blocks: blocks, garbage: garbage, blockDeleteLines: blockDeleteLines)
    }
}
