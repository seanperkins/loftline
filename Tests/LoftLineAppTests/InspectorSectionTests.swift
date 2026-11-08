import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Collapsible inspector sections remember whether they are open, per section title.
@Suite struct InspectorSectionTests {
    @Test func theStorageKeyIsADeterministicSlugOfTheTitle() {
        #expect(SectionState.key(for: "Ramps & Leads") == "loftline.inspector.expanded.ramps-leads")
        #expect(SectionState.key(for: "Last Pass") == "loftline.inspector.expanded.last-pass")
        #expect(SectionState.key(for: "  Array   Copies ") == "loftline.inspector.expanded.array-copies")
    }

    @Test func theCollapsibleTitlesDoNotShareAKey() {
        let titles = ["Last Pass", "Ramps & Leads", "Order & Corners", "Ramps", "Array Copies"]
        #expect(Set(titles.map(SectionState.key(for:))).count == titles.count)
    }
}
