import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Every setting in the toolpath forms, Job Setup and the Tool Database has a one-line tooltip:
/// either a `FieldHelp` entry for its label or an inline `help:` on the call. Beginners on the
/// forums ask what each number does; the tooltip is the answer that costs no screen space.
@Suite struct FieldHelpTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let scope = ["OperationForms", "Toolpaths2DForms", "PhotoVCarveForm", "OperationEditor", "JobSetupSheet",
                        "ToolDatabaseView", "ToolDataSections"]

    /// (file, label, line) for every labeled control whose label is a plain string.
    static func controls() throws -> [(file: String, label: String, line: String)] {
        let control = try NSRegularExpression(pattern: #"\b(?:LengthField|NumberField|IntField|Toggle|Picker)\("([^"\\]+)"|\b(?:OptionalLengthField|OptionalValueField)\(label: "([^"\\]+)""#)
        var out: [(String, String, String)] = []
        for name in scope {
            let url = root.appendingPathComponent("Sources/LoftLineApp/Panels/\(name).swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                for m in control.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    for g in 1...2 {
                        if let r = Range(m.range(at: g), in: s) { out.append((name, String(s[r]), s)) }
                    }
                }
            }
        }
        return out
    }

    @Test func everySettingInScopeHasATooltip() throws {
        let found = try Self.controls()
        #expect(found.count > 120, "the scan found only \(found.count) controls; did the forms move?")
        // An inline `help:` on the same line counts; so does `.help(` on the same line (one-line toggles).
        let missing = found.filter { FieldHelp.text(for: $0.label) == nil && !$0.line.contains("help:") && !$0.line.contains(".help(") }
        #expect(missing.isEmpty, "settings without a tooltip: \(missing.map { "\($0.file): \($0.label)" })")
    }

    @Test func tooltipsAreOneShortLine() {
        for (label, text) in FieldHelp.texts {
            #expect(!text.contains("\n"), Comment(rawValue: label))
            #expect(text.count <= 120, "\(label): \(text.count) characters")
            #expect(!text.hasSuffix("."), "\(label): tooltips do not end with a period")
            #expect(text.first?.isUppercase == true, Comment(rawValue: label))
        }
    }

    @Test func fieldHelpFallsBackToTheLabel() {
        #expect(FieldHelp.text(for: "Tab height") != nil)
        #expect(FieldHelp.text(for: "No such setting") == nil)
    }
}
