import CoreGraphics
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct WrappingLayoutTests {
    @Test func keepsEverythingOnOneLineWhenItFits() {
        let lines = WrapLines.lines(widths: [40, 40, 40], maxWidth: 140, spacing: 10)
        #expect(lines.map(\.indices) == [[0, 1, 2]])
        #expect(lines.map(\.width) == [140])
    }

    @Test func wrapsWhenTheNextItemWouldOverflow() {
        let lines = WrapLines.lines(widths: [40, 40, 40], maxWidth: 139, spacing: 10)
        #expect(lines.map(\.indices) == [[0, 1], [2]])
        #expect(lines.map(\.width) == [90, 40])
    }

    @Test func anItemWiderThanTheRowSitsAloneOnItsLine() {
        let lines = WrapLines.lines(widths: [30, 200, 30], maxWidth: 100, spacing: 10)
        #expect(lines.map(\.indices) == [[0], [1], [2]])
        #expect(lines.map(\.width) == [30, 200, 30])
    }

    @Test func emptyInputGivesNoLines() {
        #expect(WrapLines.lines(widths: [], maxWidth: 100, spacing: 10).isEmpty)
    }

    @Test func unlimitedWidthNeverWraps() {
        let lines = WrapLines.lines(widths: [500, 500, 500], maxWidth: .infinity, spacing: 10)
        #expect(lines.map(\.indices) == [[0, 1, 2]])
    }

    @Test func zeroWidthPutsEveryItemOnItsOwnLine() {
        // SwiftUI asks for the minimum size with a zero-width proposal.
        let lines = WrapLines.lines(widths: [40, 60, 20], maxWidth: 0, spacing: 10)
        #expect(lines.map(\.indices) == [[0], [1], [2]])
    }

    @Test func preservesOrderAcrossManyLines() {
        let lines = WrapLines.lines(widths: Array(repeating: 30, count: 10), maxWidth: 100, spacing: 10)
        #expect(lines.flatMap(\.indices) == Array(0..<10))
        #expect(lines.allSatisfy { $0.indices.count <= 3 })
    }
}
