import CADCore
import Foundation

/// A machine's manual tool change with a touch plate: park the gantry for the swap, move to the job's touch-off spot,
/// probe down onto a plate lying on the material and set Z from it. Values are in the machine's units; park and
/// traverse heights are machine coordinates (`G53`): machine Z 0 is the top of travel and Z is negative downward.
public struct ToolChangeProbe: Codable, Hashable, Sendable {
    public enum Controller: String, Codable, CaseIterable, Sendable {
        /// `G38.2`, which alarms when it ends without contact; Z set with `G10 L20`.
        case grbl
        /// `G31`, which does not stop without contact; the owner's macro checks contact and sets Z.
        case mach4

        public var displayName: String { self == .grbl ? "GRBL" : "Mach4" }
        public var probeCode: String { self == .grbl ? "G38.2" : "G31" }
    }

    public var parkX: Double
    public var parkY: Double
    /// How far the spindle comes down at the park for the swap (machine Z, `≤ topZ`).
    public var parkZ: Double
    /// Machine Z of every X/Y traverse of the sequence.
    public var topZ: Double
    public var plateThickness: Double
    /// The plate's greatest extent (its diagonal, or a round plate's diameter).
    public var plateSize: Double
    /// Units per minute.
    public var probeFeed: Double
    public var probeTravel: Double
    public var controller: Controller
    /// Mach4: the owner's macro `M{n} P{plate Z}`, which stops the program without contact and otherwise sets the active
    /// work offset so the current Z reads P.
    public var mach4ZeroMacro: Int?
    /// 1 to 6 (`G54` to `G59`): selected by the sequence and the offset whose Z is set.
    public var workOffset: Int

    public init(parkX: Double, parkY: Double, parkZ: Double, topZ: Double = 0, plateThickness: Double, plateSize: Double,
                probeFeed: Double, probeTravel: Double, controller: Controller, mach4ZeroMacro: Int? = nil,
                workOffset: Int = 1) {
        self.parkX = parkX; self.parkY = parkY; self.parkZ = parkZ; self.topZ = topZ
        self.plateThickness = plateThickness; self.plateSize = plateSize; self.probeFeed = probeFeed
        self.probeTravel = probeTravel; self.controller = controller; self.mach4ZeroMacro = mach4ZeroMacro
        self.workOffset = workOffset
    }

    /// Starting values for a machine that switches probing on: a common 1/2 in (12 mm) plate, a slow feed, the controller
    /// its posts speak (GRBL when it lists the GRBL post). The park position is the owner's to set.
    public static func defaults(for machine: MachineDefinition) -> ToolChangeProbe {
        let grbl = machine.postIDs.contains(BuiltInPosts.genericGRBLMM.id)
        let mm = LengthUnit.millimeter.factor(to: machine.units)
        let inch = LengthUnit.inch.factor(to: machine.units)
        let quarter = -machine.limits.zTravel / 4
        let top = grbl ? -1 * mm : 0
        return ToolChangeProbe(parkX: 0, parkY: 0, parkZ: max(quarter, top - 0.5 * inch), topZ: top,
                               plateThickness: 0.5 * inch, plateSize: 3 * inch, probeFeed: 5 * inch, probeTravel: 0.5 * inch,
                               controller: grbl ? .grbl : .mach4, mach4ZeroMacro: grbl ? nil : 199)
    }

    /// Lengths and the feed multiplied by `f` (a units change); the work offset and the macro number stay.
    public func scaled(by f: Double) -> ToolChangeProbe {
        var p = self
        p.parkX *= f; p.parkY *= f; p.parkZ *= f; p.topZ *= f
        p.plateThickness *= f; p.plateSize *= f; p.probeFeed *= f; p.probeTravel *= f
        return p
    }

    /// The slowest probe feed overshoots negligibly after contact; the probe starts at or above the plate top, so a
    /// travel no longer than the plate never takes a missed probe below the material top.
    static let maxFeedInchesPerMinute = 10.0
    static let maxTravelInches = 1.0
    /// GRBL puts machine Z 0 at the limit switch's trigger point after homing, whatever its pull-off.
    static let grblTopClearanceMM = 1.0

    /// Why these settings cannot post, for the Machines editor and the builder. `limits` and `units` are the machine's.
    public func problems(limits: MachineLimits, units: LengthUnit) -> [String] {
        let inch = units.factor(to: .inch), u = units.abbreviation
        let tol = 1e-9 * max(1, limits.zTravel)
        func fmt(_ v: Double) -> String { String(format: "%g", v) }
        var out: [String] = []
        let lowest = -limits.zTravel / 4
        if topZ > tol { out.append("Traverse height must be at or below machine Z 0 (the top of travel).") }
        if topZ < lowest - tol { out.append("Traverse height must be within the top quarter of Z travel (\(fmt(lowest)) \(u) or higher).") }
        if controller == .grbl, topZ > -Self.grblTopClearanceMM * LengthUnit.millimeter.factor(to: units) + tol {
            out.append("On GRBL the traverse height must be at least 1 mm below machine Z 0, which is the limit switch.")
        }
        if parkZ > topZ + tol { out.append("Park Z must be at or below the traverse height.") }
        if parkZ < lowest - tol { out.append("Park Z must be within the top quarter of Z travel (\(fmt(lowest)) \(u) or higher).") }
        if abs(parkX) > limits.xTravel + tol { out.append("Park X is beyond the machine's X travel.") }
        if abs(parkY) > limits.yTravel + tol { out.append("Park Y is beyond the machine's Y travel.") }
        if !(plateThickness > 0) { out.append("Plate thickness must be more than 0.") }
        if !(plateSize > 0) { out.append("Plate size must be more than 0.") }
        if !(probeFeed > 0) { out.append("Probe feed must be more than 0.") }
        if probeFeed * inch > Self.maxFeedInchesPerMinute * (1 + 1e-9) {
            out.append("Probe feed must be at most 10 in/min (254 mm/min).")
        }
        if !(probeTravel > 0) { out.append("Probe travel must be more than 0.") }
        if probeTravel * inch > Self.maxTravelInches * (1 + 1e-9) { out.append("Probe travel must be at most 1 in (25.4 mm).") }
        if probeTravel > plateThickness * (1 + 1e-9) {
            out.append("Probe travel must be no more than the plate thickness, so a missed contact stops above the material.")
        }
        if !(1...6).contains(workOffset) { out.append("Work offset must be 1 to 6 (G54 to G59).") }
        if controller == .mach4 {
            if let m = mach4ZeroMacro {
                if !(100...999).contains(m) { out.append("The Mach4 zero macro must be M100 to M999.") }
            } else {
                out.append("Mach4 needs the number of your zero macro (it checks the contact and sets Z).")
            }
        }
        return out
    }
}

/// What the effective post does at a tool change, worked out from the machine and the post when a job is posted.
public enum ProbeSetting: Hashable, Sendable {
    case on(ToolChangeProbe)
    /// Probing was asked for but cannot be done with this machine or post: the builder refuses with the message.
    case refused(String)
}
