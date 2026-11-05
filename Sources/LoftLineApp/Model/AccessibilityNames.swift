import CADCore
import Foundation
import LoftLineKit

/// What VoiceOver says for controls that are drawn as a symbol or carry an arrow glyph in their title.
/// Pure, so the wording can be tested.
enum AccessibilityNames {
    /// "Origin: lower left": the XY-origin dots are bare circles, so they need a position in words.
    static func origin(_ origin: XYOrigin) -> String { "Origin: " + origin.displayName.lowercased() }

    /// "Mirror horizontally": for buttons titled "Mirror ↔", whose glyph VoiceOver would read as an arrow.
    static func directional(_ verb: String, horizontally: Bool) -> String {
        verb + (horizontally ? " horizontally" : " vertically")
    }
}
