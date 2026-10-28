import Foundation

/// Where the machine's Z = 0 is touched off.
public enum ZZeroMode: String, Codable, CaseIterable, Sendable {
    /// Z0 on top of the material (touch plate on the stock).
    case materialTop
    /// Z0 on the spoilboard / machine bed (material top is at Z = thickness).
    case spoilboard
}

/// Where machine X0 Y0 sits relative to the material.
public enum XYOrigin: String, Codable, CaseIterable, Sendable {
    case lowerLeft, lowerRight, upperLeft, upperRight, center
}

/// Job Setup ("material") — all lengths in the document's units.
/// Document geometry always uses a material frame with (0,0) at the material's lower-left
/// corner, X to the right, Y up. `xyOrigin` only affects machine coordinates (G-code).
public struct JobSetup: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public var thickness: Double
    public var xyOrigin: XYOrigin
    public var zZero: ZZeroMode
    /// Rapid clearance height ABOVE the material top (VCarve "Z1 safe Z").
    public var safeZ: Double
    /// Height above the material top for the start/end home position (VCarve "Z2").
    public var homeZ: Double
    /// Home XY in machine coordinates (relative to the chosen XY origin).
    public var home: Vec2
    /// Material name; tools with cutting data for it use that data (toolpaths-2d addition).
    public var material: String?
    /// Double-sided machining (nil = single-sided). See `TwoSided.swift`.
    public var twoSided: TwoSidedSetup?
    /// Plunge gap ("Z2"): height above the material (or above already-cleared material) down to
    /// which the tool rapids before feeding at the plunge rate. nil = generator default
    /// (0.05 in / 1 mm for 2D, 0.04 in / 1 mm for 3D, V-carve plunges from safe Z).
    public var plungeGap: Double?
    /// Offset of the machine XY datum from the chosen corner/centre (material frame, document
    /// units). nil = no offset.
    public var datumOffset: Vec2?
    /// Where the touch plate goes on the material when the machine re-zeroes Z on a plate at each tool change
    /// (material frame, document units). nil = not set.
    public var touchOffSpot: Vec2?

    public init(width: Double = 24, height: Double = 18, thickness: Double = 0.75,
                xyOrigin: XYOrigin = .lowerLeft, zZero: ZZeroMode = .materialTop,
                safeZ: Double = 0.2, homeZ: Double = 0.8, home: Vec2 = .zero) {
        self.width = width; self.height = height; self.thickness = thickness
        self.xyOrigin = xyOrigin; self.zZero = zZero; self.safeZ = safeZ; self.homeZ = homeZ
        self.home = home
    }

    /// Default job for a unit system (inch: 24x18x0.75, mm: 600x450x18).
    public static func defaults(for units: LengthUnit) -> JobSetup {
        switch units {
        case .inch: return JobSetup()
        case .millimeter:
            return JobSetup(width: 600, height: 450, thickness: 18, safeZ: 5, homeZ: 20)
        }
    }

    public var materialBounds: Rect2 { Rect2(x: 0, y: 0, width: width, height: height) }

    /// Position of the machine XY origin in the document/material frame.
    public var originInMaterialFrame: Vec2 {
        let corner: Vec2
        switch xyOrigin {
        case .lowerLeft: corner = Vec2(0, 0)
        case .lowerRight: corner = Vec2(width, 0)
        case .upperLeft: corner = Vec2(0, height)
        case .upperRight: corner = Vec2(width, height)
        case .center: corner = Vec2(width / 2, height / 2)
        }
        return corner + (datumOffset ?? .zero)
    }

    /// Plunge gap to use: the job's value (capped at safe Z) or `defaultGap`.
    public func effectivePlungeGap(default defaultGap: Double) -> Double {
        min(safeZ, max(plungeGap ?? defaultGap, 0))
    }

    /// Scale every length by `factor` (used when switching document units).
    public func scaled(by f: Double) -> JobSetup {
        var j = self
        j.width *= f; j.height *= f; j.thickness *= f; j.safeZ *= f; j.homeZ *= f; j.home = j.home * f
        j.plungeGap = plungeGap.map { $0 * f }
        j.datumOffset = datumOffset.map { $0 * f }
        j.touchOffSpot = touchOffSpot.map { $0 * f }
        return j
    }
}
