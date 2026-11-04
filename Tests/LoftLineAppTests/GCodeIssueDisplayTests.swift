import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct GCodeIssueDisplayTests {
    let plunge = "Rapid plunge below the material top to Z-0.1050; use a feed move (14 more)"

    @Test func theSameCheckOnToolpathsAndOnTheTextIsListedOnce() {
        // The toolpath check has no line; the G-code check has one. Keep the one that says where.
        let merged = GCodeIssue.merged([
            GCodeIssue(severity: .warning, message: plunge),
            GCodeIssue(severity: .warning, line: 1156, message: plunge),
        ])
        #expect(merged == [GCodeIssue(severity: .warning, line: 1156, message: plunge)])
    }

    @Test func differentMessagesAndSeveritiesAreKeptInOrder() {
        let a = GCodeIssue(severity: .warning, message: "a")
        let b = GCodeIssue(severity: .error, message: "a")  // same text, but an error
        let c = GCodeIssue(severity: .warning, line: 3, message: "c")
        #expect(GCodeIssue.merged([a, c, b, a]) == [a, c, b])
    }

    @Test func theEarliestLineWinsWhenSeveralLinesShareAMessage() {
        let merged = GCodeIssue.merged([
            GCodeIssue(severity: .warning, line: 90, message: "x"),
            GCodeIssue(severity: .warning, line: 12, message: "x"),
        ])
        #expect(merged.map(\.line) == [12])
    }

    @Test func displayTextDropsTheRedundantSeverityWord() {
        #expect(GCodeIssue(severity: .warning, line: 1156, message: "m").displayText == "Line 1156: m")
        #expect(GCodeIssue(severity: .error, message: "m").displayText == "m")
    }
}
