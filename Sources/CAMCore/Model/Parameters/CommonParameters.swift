import Foundation

// All lengths are in document units; depths are measured DOWN from the material top
// (positive = into the material). Default values assume inches — the UI rescales them for
// millimetre documents (multiply by 25.4).

public enum CutDirection: String, Codable, CaseIterable, Sendable {
    case climb, conventional
}

public enum RampType: String, Codable, CaseIterable, Sendable {
    /// Linear zig-zag ramp along the path.
    case zigzag
    /// Spiral/helical descent following the path.
    case spiral
    /// Smooth ramp blended into the start of the cut.
    case smooth
}

public struct RampSettings: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var type: RampType
    /// Horizontal ramp length (used by zigzag/smooth).
    public var length: Double
    /// Maximum ramp angle in degrees (limits steepness when length is too short). Ramps are built at
    /// 0.5° or more; a vector too short to keep the angle, or an angle under 0.5°, gets a warning.
    public var maxAngle: Double

    public init(isEnabled: Bool = false, type: RampType = .smooth, length: Double = 1.0, maxAngle: Double = 10) {
        self.isEnabled = isEnabled; self.type = type; self.length = length; self.maxAngle = maxAngle
    }
}

/// Depth range + per-pass stepdown shared by most operations.
public struct DepthSettings: Codable, Hashable, Sendable {
    public var startDepth: Double
    public var cutDepth: Double
    /// Max depth per pass; nil = use the tool's stepdown.
    public var passDepth: Double?
    /// Optional shallower final pass (0 = none).
    public var finalPassDepth: Double
    /// Hand-edited pass depths (below the top). When set they replace the computed passes; the cut
    /// depth is always the last pass (toolpaths-2d addition; nil = computed).
    public var customPasses: [Double]?
    /// Keep every pass exactly the pass depth apart (the remainder goes in the last roughing pass)
    /// instead of dividing the depth evenly (toolpaths-2d addition; nil = even).
    public var exactStep: Bool?
    /// The cut depth was set from the material thickness (a through cut): when Job Setup changes
    /// the thickness, the cut depth moves by the same amount, so it stays the same distance past
    /// the bottom. nil = a fixed depth. Kept outside the generators: `cutDepth` is always absolute.
    public var followsThickness: Bool?

    public init(startDepth: Double = 0, cutDepth: Double = 0.25, passDepth: Double? = nil, finalPassDepth: Double = 0) {
        self.startDepth = startDepth; self.cutDepth = cutDepth; self.passDepth = passDepth
        self.finalPassDepth = finalPassDepth
    }

    /// Pass depths from startDepth (exclusive) to cutDepth (inclusive), evenly spaced and
    /// never deeper than `stepdown` apart. Shared helper so every op paces passes the same way.
    /// At most this many computed passes: a tiny or zero step (a typo in a field) must never
    /// turn into millions of passes. Operations reject a non-positive step first
    /// (`validatePassDepth`); this only keeps the helper bounded for previews.
    public static let maxComputedPasses = 10_000

    /// Throws when the step that `passDepths` would use is not a positive number (a pass depth
    /// or tool stepdown of 0 or less). Hand-edited passes do not use the step.
    public func validatePassDepth(toolStepdown: Double) throws {
        if let custom = customPasses, !custom.isEmpty { return }
        let step = passDepth ?? toolStepdown
        guard step.isFinite, step > 0 else {
            throw CAMError.invalidParameter(passDepth != nil ? "Pass depth must be positive"
                                                             : "Tool pass depth (stepdown) must be positive")
        }
    }

    public func passDepths(toolStepdown: Double) -> [Double] {
        let total = cutDepth - startDepth
        // Not a number or not finite (-1e308 to 1e308 overflows): no passes, rather than a trap in the count below.
        guard total > 1e-12, total.isFinite else { return [] }
        let raw = passDepth ?? toolStepdown
        let step = max(raw.isFinite && raw > 0 ? raw : total, total / Double(Self.maxComputedPasses))
        if let custom = customPasses, !custom.isEmpty {
            var depths: [Double] = []
            for d in custom.sorted() where d > startDepth + 1e-9 && d < cutDepth - 1e-9 {
                if let l = depths.last, d - l < 1e-9 { continue }
                depths.append(d)
            }
            return depths + [cutDepth]
        }
        let finalPass = finalPassDepth > 0 && finalPassDepth < total ? finalPassDepth : 0
        let roughTotal = total - finalPass
        let n = max(1, Int(ceil(roughTotal / step - 1e-9)))
        var depths: [Double]
        if exactStep == true {
            depths = (1..<n).map { startDepth + step * Double($0) } + [startDepth + roughTotal]
        } else {
            depths = (1...n).map { startDepth + roughTotal * Double($0) / Double(n) }
        }
        if finalPass > 0 { depths.append(cutDepth) }
        return depths
    }
}
