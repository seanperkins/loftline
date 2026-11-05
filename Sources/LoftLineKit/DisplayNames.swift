import CADCore
import Foundation

/// Number style used by all length/feed fields.
public let decimalFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...4)).grouping(.never)

extension LengthUnit {
    public var displayName: String { self == .inch ? "Inches" : "Millimeters" }
    public var feedUnit: String { self == .inch ? "in/min" : "mm/min" }
}

extension XYOrigin {
    public var displayName: String {
        switch self {
        case .lowerLeft: return "Lower left"
        case .lowerRight: return "Lower right"
        case .upperLeft: return "Upper left"
        case .upperRight: return "Upper right"
        case .center: return "Center"
        }
    }
}

extension ZZeroMode {
    public var displayName: String { self == .materialTop ? "Material surface" : "Machine bed (spoilboard)" }
    /// For tight spaces such as the status bar.
    public var shortName: String { self == .materialTop ? "Material" : "Bed" }
}
