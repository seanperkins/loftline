import CADCore
import Foundation

/// Vertical position of a 3D model inside the material, expressed as the gaps above and below
/// it (the model's own height stays as set).
extension ModelPlacementForm {
    public enum ZAnchor: String, CaseIterable, Identifiable {
        case top, center, bottom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .top: return "Top"
            case .center: return "Center"
            case .bottom: return "Bottom"
            }
        }
    }

    /// Material left above the model's highest point (= Z offset below the top).
    public var gapAbove: Double {
        get { zOffset }
        set { zOffset = max(newValue, 0) }
    }

    /// Material left below the model's lowest point.
    public var gapBelow: Double {
        get { job.thickness - zOffset - zHeight }
        set { zOffset = max(job.thickness - zHeight - max(newValue, 0), 0) }
    }

    /// Puts the model at the top, centre or bottom of the material thickness.
    public mutating func anchor(_ a: ZAnchor) {
        let spare = max(job.thickness - zHeight, 0)
        switch a {
        case .top: zOffset = 0
        case .center: zOffset = spare / 2
        case .bottom: zOffset = spare
        }
    }

    /// Stretches the model's Z height to fill the material between the two gaps.
    public mutating func fillBetweenGaps(above: Double, below: Double) {
        let h = job.thickness - max(above, 0) - max(below, 0)
        guard h > 0 else { return }
        zOffset = max(above, 0)
        zHeight = h
    }
}
