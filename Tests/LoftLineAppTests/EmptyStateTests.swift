import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct EmptyStateTests {
    @Test func everyEmptyStateExplainsAndPointsAtTheNextStep() {
        for state in [EmptyState.noToolpaths, .noObjects] {
            #expect(!state.title.isEmpty && !state.systemImage.isEmpty)
            #expect(state.detail.hasSuffix(".") || state.detail.hasSuffix("…"), "a full sentence: \(state.detail)")
        }
        #expect(EmptyState.noToolpaths.detail.contains("New Toolpath"))
        #expect(EmptyState.noObjects.detail.contains("Import"))
        #expect(EmptyState.noToolpaths.title != EmptyState.noObjects.title)
    }
}
