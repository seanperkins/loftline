import CADCore
import Foundation

/// What the Tabs section says about the tabs' real thickness.
public struct TabHoldNote: Equatable {
    public var text: String
    /// True when the tabs would hold nothing, so the note should read as a warning.
    public var isProblem: Bool
}

/// A tab's height is measured up from the bottom of the cut, not from the material bottom, so a cut that
/// passes below the material bottom (to clear the spoilboard) leaves a thinner tab than the number in the
/// field, and none at all once the overcut reaches the tab height.
public enum TabHold {
    public static func note(tabHeight height: Double, cutDepth: Double, materialThickness: Double,
                     units: LengthUnit) -> TabHoldNote {
        let tolerance = units == .inch ? 0.0005 : 0.01
        let u = units.abbreviation
        let over = cutDepth - materialThickness
        if over < -tolerance {
            return TabHoldNote(text: "The cut stops above the material bottom, so tabs are not needed.", isProblem: false)
        }
        if over <= tolerance {
            return TabHoldNote(text: "Tabs hold \(DepthText.number(height)) \(u) of material.", isProblem: false)
        }
        let held = height - over
        let below = "The cut goes \(DepthText.number(over)) \(u) below the material bottom, so tabs hold "
        if held <= tolerance {
            return TabHoldNote(text: below + "nothing. Raise the tab height or reduce the cut depth.", isProblem: true)
        }
        return TabHoldNote(text: below + "\(DepthText.number(held)) \(u) of material.", isProblem: false)
    }
}
