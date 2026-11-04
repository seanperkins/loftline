import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Tab height is measured up from the bottom of the cut, so a cut that passes below the material
/// bottom leaves a thinner tab than the number in the field. The note says what a tab really holds.
@Suite struct TabHoldTests {
    func note(height: Double, depth: Double, thickness: Double = 0.75, units: LengthUnit = .inch) -> TabHoldNote {
        TabHold.note(tabHeight: height, cutDepth: depth, materialThickness: thickness, units: units)
    }

    @Test func holdsTheWholeHeightWhenTheCutStopsAtTheBottom() {
        let n = note(height: 0.125, depth: 0.75)
        #expect(n.text == "Tabs hold 0.125 in of material.")
        #expect(!n.isProblem)
    }

    @Test func deductsWhatTheCutPassesBelowTheBottom() {
        let n = note(height: 0.125, depth: 0.77)
        #expect(n.text == "The cut goes 0.02 in below the material bottom, so tabs hold 0.105 in of material.")
        #expect(!n.isProblem)
    }

    @Test func holdsNothingWhenTheOvercutIsAsBigAsTheTab() {
        let n = note(height: 0.02, depth: 0.77)
        #expect(n.text == "The cut goes 0.02 in below the material bottom, so tabs hold nothing. Raise the tab height or reduce the cut depth.")
        #expect(n.isProblem)
        #expect(note(height: 0.01, depth: 0.77).isProblem)
    }

    @Test func saysTabsAreNotNeededWhenTheCutStopsShort() {
        let n = note(height: 0.125, depth: 0.5)
        #expect(n.text == "The cut stops above the material bottom, so tabs are not needed.")
        #expect(!n.isProblem)
    }

    @Test func worksInMillimeters() {
        let n = note(height: 3, depth: 18.5, thickness: 18, units: .millimeter)
        #expect(n.text == "The cut goes 0.5 mm below the material bottom, so tabs hold 2.5 mm of material.")
        #expect(!n.isProblem)
    }

    @Test func ignoresRoundingNoiseAtTheBottom() {
        // 0.75 + 0.0002 is "at the bottom" to the tolerance, not an overcut.
        #expect(note(height: 0.125, depth: 0.7502).text == "Tabs hold 0.125 in of material.")
    }
}
