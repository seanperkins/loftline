import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The app's defaults are inches and an American machine, so its text is American English. This scans
/// string literals (single-line and multi-line help text) for the British spellings that had crept in;
/// identifiers and comments are not checked.
@Suite struct SpellingTests {
    static let british = try! NSRegularExpression(
        pattern: #"\b(colour|centre|millimetre|metre|customis|behaviour|optimis|organis|recognis|grey|labelled|neighbour|centred|analyse|catalogue|licence|bevelled|practise)\w*"#,
        options: .caseInsensitive)

    /// The text of every string literal on `line`, or the whole line inside a multi-line string.
    static func literalText(of line: String, inMultiline: Bool) -> [String] {
        if inMultiline { return [line] }
        var found: [String] = []
        var current: String?
        var escaped = false
        for ch in line {
            if current != nil {
                if escaped { escaped = false; current! .append(ch); continue }
                if ch == "\\" { escaped = true; current!.append(ch); continue }
                if ch == "\"" { found.append(current!); current = nil; continue }
                current!.append(ch)
            } else if ch == "\"" {
                current = ""
            }
        }
        return found
    }

    @Test func userVisibleTextIsAmericanEnglish() throws {
        var offenders: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: ShortcutTests.sourceRoot, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            var inMultiline = false
            for (n, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let delimiters = line.components(separatedBy: "\"\"\"").count - 1
                if !trimmed.hasPrefix("//") {
                    for text in Self.literalText(of: line, inMultiline: inMultiline && delimiters == 0) {
                        let range = NSRange(text.startIndex..., in: text)
                        if let m = Self.british.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                            offenders.append("\(url.lastPathComponent):\(n + 1) \(text[r])")
                        }
                    }
                }
                if delimiters % 2 == 1 { inMultiline.toggle() }
            }
        }
        #expect(offenders.isEmpty, "British spellings in user-visible text: \(offenders.prefix(12))")
    }
}
