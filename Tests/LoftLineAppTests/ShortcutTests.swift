import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Keyboard shortcuts, read from the source so a new binding cannot quietly clash.
@Suite struct ShortcutTests {
    /// Standard macOS shortcuts from the HIG "Keyboards" table that apps should not repurpose.
    /// Deliberately absent: ⌘G / ⇧⌘G (Group / Ungroup follow the drawing-app convention; LoftLine has no Find).
    static let reserved: Set<String> = ["⌥⌘T", "⌘I", "⌘[", "⌘]", "⌥⌘F", "⌘J"]

    static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LoftLineApp")
    }

    /// "⇧⌘I"-style names of every `.keyboardShortcut("x", modifiers: …)` with a literal key.
    static func bindings() throws -> [(name: String, file: String)] {
        let pattern = try NSRegularExpression(
            pattern: #"\.keyboardShortcut\(\s*"((?:\\.|[^"\\])+)"\s*(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?\s*\)"#)
        var found: [(String, String)] = []
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for m in pattern.matches(in: text, range: range) {
                let key = String(text[Range(m.range(at: 1), in: text)!])
                let mods = m.range(at: 2).location == NSNotFound ? ".command" : String(text[Range(m.range(at: 2), in: text)!])
                var symbols = ""
                for (word, symbol) in [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
                where mods.contains(word) { symbols += symbol }
                found.append((symbols + key.uppercased(), url.lastPathComponent))
            }
        }
        return found
    }

    @Test func noShortcutIsUsedTwice() throws {
        let names = try Self.bindings().map(\.name)
        // The scanner must find the menu before its verdicts mean anything.
        #expect(names.count >= 20 && names.contains("⌘P"), "shortcut scanner found \(names.count) bindings")
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(duplicates.isEmpty, "Used more than once: \(duplicates)")
    }

    @Test func noShortcutRepurposesAStandardOne() throws {
        let clashes = try Self.bindings().map(\.name).filter { Self.reserved.contains($0) }
        #expect(clashes.isEmpty, "Standard macOS shortcuts reused: \(clashes)")
    }

    @Test func helpListsTheCurrentBindings() throws {
        let text = HelpTopic.shortcuts.body
        for name in ["⇧⌘I", "⌥⌘P", "⌥⌘[", "⌥⌘]"] where try Self.bindings().map(\.name).contains(name) {
            #expect(text.contains(name), "Help does not mention \(name)")
        }
        #expect(!text.contains("⌥⌘T"))
    }
}
