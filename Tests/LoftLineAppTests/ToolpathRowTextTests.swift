import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct ToolpathRowTextTests {
    @Test func summaryNamesTheKindAndEachToolOnce() {
        #expect(ToolpathRowText.summary(kind: "Pocket", tools: ["T1"]) == "Pocket · T1")
        #expect(ToolpathRowText.summary(kind: "Pocket", tools: ["T1", "T6", "T1"]) == "Pocket · T1+T6")
    }

    @Test func aToolpathWithoutToolsHasNoDanglingSeparator() {
        // A merged toolpath references no tool of its own.
        #expect(ToolpathRowText.summary(kind: "Merged", tools: []) == "Merged")
    }

    @Test func aMissingToolIsSaidSo() {
        #expect(ToolpathRowText.summary(kind: "Profile", tools: ["missing tool"]) == "Profile · missing tool")
    }
}
