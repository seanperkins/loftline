import AppKit
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IconTests {
    @Test func theToolPaletteIsGroupedByKindOfTool() {
        let groups = CanvasTool.groups
        #expect(groups.flatMap { $0 } == CanvasTool.allCases, "every tool appears once, in palette order")
        #expect(groups.count == 4)
        #expect(groups[0] == [.select, .nodeEdit])
        #expect(groups[1].contains(.rectangle) && groups[1].contains(.star))
        #expect(groups[2].contains(.polyline) && groups[2].contains(.freehand))
        #expect(groups[3] == [.text, .trim, .measure, .dimension])
    }

    @Test func everySymbolNameInTheSourceExists() throws {
        let pattern = try NSRegularExpression(pattern: #"(?:systemName|systemImage|systemSymbolName):\s*"([a-z0-9.]+)""#)
        var missing: [String] = []
        for case let url as URL in FileManager.default.enumerator(at: ShortcutTests.sourceRoot, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = String(text[Range(m.range(at: 1), in: text)!])
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { missing.append("\(url.lastPathComponent): \(name)") }
            }
        }
        #expect(missing.isEmpty, "No such SF Symbol: \(missing)")
    }

    @Test func everyToolHasASymbolOrItsOwnGlyph() {
        for tool in CanvasTool.allCases where !tool.hasCustomGlyph {
            #expect(NSImage(systemSymbolName: tool.systemImage, accessibilityDescription: nil) != nil, "\(tool)")
        }
        #expect(CanvasTool.arc.hasCustomGlyph)
    }
}
