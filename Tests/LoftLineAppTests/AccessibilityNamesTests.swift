import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// What VoiceOver says for controls that are drawn as a symbol or with an arrow glyph.
@Suite struct AccessibilityNamesTests {
    @Test func everyOriginHasItsOwnSpokenName() {
        let names = XYOrigin.allCases.map(AccessibilityNames.origin)
        #expect(Set(names).count == XYOrigin.allCases.count)
        #expect(names.allSatisfy { $0.hasPrefix("Origin: ") })
        #expect(AccessibilityNames.origin(.lowerLeft) == "Origin: " + XYOrigin.lowerLeft.displayName.lowercased())
        #expect(AccessibilityNames.origin(.center) == "Origin: " + XYOrigin.center.displayName.lowercased())
    }

    @Test func directionalButtonsSayHorizontallyOrVertically() {
        #expect(AccessibilityNames.directional("Mirror", horizontally: true) == "Mirror horizontally")
        #expect(AccessibilityNames.directional("Distribute", horizontally: false) == "Distribute vertically")
    }

    @Test func spokenNamesCarryNoArrowGlyphs() {
        let arrows = CharacterSet(charactersIn: "↔↕←→↑↓")
        let names = XYOrigin.allCases.map(AccessibilityNames.origin)
            + [AccessibilityNames.directional("Space", horizontally: true)]
        #expect(names.allSatisfy { $0.rangeOfCharacter(from: arrows) == nil })
    }
}
