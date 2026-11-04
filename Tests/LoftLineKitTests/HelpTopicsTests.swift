import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct HelpTopicsTests {
    @Test func everyTopicHasContent() {
        for t in HelpTopic.allCases {
            #expect(!t.title.isEmpty)
            #expect(t.body.count > 80, "\(t) body is too short")
            #expect(!t.related.contains(t), "\(t) links to itself")
            #if os(macOS)   // Foundation has no Markdown parser off the Mac.
            // Bodies must parse as inline Markdown paragraph by paragraph.
            for block in t.body.components(separatedBy: "\n\n") {
                #expect((try? AttributedString(markdown: block)) != nil)
            }
            #endif
        }
        #expect(Set(HelpTopic.allCases.map(\.title)).count == HelpTopic.allCases.count)
    }

    @Test func everyOperationHasATopic() {
        for kind in OperationKind.allCases {
            let t = HelpTopic.forOperation(kind)
            #expect(t.title.contains(kind == .drill ? "Drilling" : kind.displayName))
        }
    }

    @Test func searchMatchesAllWords() {
        #expect(HelpTopic.search("").count == HelpTopic.allCases.count)
        #expect(HelpTopic.search("tabs").contains(.tabs))
        #expect(HelpTopic.search("spoilboard touch").contains(.jobSetup))
        #expect(HelpTopic.search("zzzz-nothing").isEmpty)
    }

    @Test func fieldTooltipsCoverCommonFields() {
        for label in ["Cut depth", "Pass depth", "Allowance", "Safe Z", "Flat depth", "Glue gap", "Stepover"] {
            #expect(FieldHelp.text(for: label) != nil, "\(label) has no tooltip")
        }
        #expect(FieldHelp.text(for: "Nonexistent field") == nil)
    }
}
