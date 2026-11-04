import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Which Arrange commands make sense for how many selected shapes, so menu items are disabled
/// rather than silently doing nothing.
@Suite struct ArrangeAvailabilityTests {
    @Test func nothingSelectedDisablesEveryCommand() {
        let a = ArrangeAvailability(selectionCount: 0)
        #expect(!a.any && !a.pair && !a.triple)
        #expect(AlignMode.allCases.allSatisfy { !a.canAlign($0) })
    }

    @Test func oneShapeCanBeCentredOnTheMaterialButNotAlignedToAnother() {
        let a = ArrangeAvailability(selectionCount: 1)
        #expect(a.any && !a.pair)
        #expect(a.canAlign(.materialCenter))
        #expect(!a.canAlign(.left) && !a.canAlign(.top))
    }

    @Test func twoShapesCanBeAlignedGroupedAndCombinedButNotDistributed() {
        let a = ArrangeAvailability(selectionCount: 2)
        #expect(a.pair && !a.triple)
        #expect(AlignMode.allCases.allSatisfy { a.canAlign($0) })
    }

    @Test func threeShapesCanBeDistributed() {
        #expect(ArrangeAvailability(selectionCount: 3).triple)
        #expect(ArrangeAvailability(selectionCount: 9).triple)
    }

    @Test func drawMenuTitlesShowTheToolKey() {
        #expect(CanvasTool.rectangle.titleWithKey == "Rectangle (R)")
        #expect(CanvasTool.select.titleWithKey == "Select (V)")
        // A tool without a key is just its name.
        #expect(CanvasTool.polygon.titleWithKey == "Polygon")
    }
}
