import CADCore
import CAMCore
import Foundation

/// Walks a program's park-and-probe tool changes state by state (spec §6), independently of the builder: the park and
/// the touch-off spot are recomputed from the machine and the job, and the Z the zero sets from the single Z-zero helper.
/// `GCodeValidator.validate(gcode:)` asks it about every block before handling the block itself; a block it consumes
/// (the machine-coordinate moves, the spot rapid, the probe unit, the zero) is not checked again as an ordinary move.
struct ProbeSequenceChecker {
    enum State: Equatable {
        case needsProbe, parked, swapReady, swapped, leaving, atSpot, placed, probed, zeroedAtSpot, cleared, ready
        indirect case lifted(from: State)
    }

    /// What the validator does with the block after the checker has seen it.
    struct Effect {
        /// Blocks consumed, starting with this one (0 = check the block as usual).
        var consumed = 0
        /// The machine moved in machine coordinates: X, Y and Z are unknown.
        var positionUnknown = false
        var xy: Vec2?
        var z: Double?
        /// After the probe: the motion mode is unknown and the next axis block must name one.
        var afterProbe = false
    }

    let probe: ToolChangeProbe
    let profile: PostProfile
    let spot: Vec2?
    let plateZ: Double
    let clearZ: Double
    let tol: Double
    let feedTol: Double
    let recoveryLine: [GCodeBlock.Word]

    private(set) var state: State = .needsProbe
    /// From the zero until a block first moves X/Y off the spot, nothing may go below clear Z.
    private var spotGate = false
    private var activeOffset: Int?

    /// `job` in `jobUnits`; everything is compared in the program's (the profile's) units.
    init(probe: ToolChangeProbe, profile: PostProfile, job: JobSetup, jobUnits: LengthUnit) {
        self.probe = probe
        self.profile = profile
        let setup = job.scaled(by: jobUnits.factor(to: profile.units))
        let coords = MachineCoordinates(job: setup)
        spot = setup.touchOffSpot.map { coords.machineXY($0) }
        plateZ = coords.z(aboveTop: probe.plateThickness)
        clearZ = coords.z(aboveTop: probe.plateThickness + setup.safeZ)
        tol = 0.5 * pow(10, -Double(profile.decimals)) + 1e-9
        feedTol = 0.5 * pow(10, -Double(profile.feedDecimals)) + 1e-9
        let line = "G17 G40 G49 G80 G90 G94 \(profile.arcOutput == .absoluteIJ ? "G90.1" : "G91.1") \(profile.unitsCode) "
            + "G\(53 + probe.workOffset)"
        recoveryLine = GCodeParser.parse(line).blocks.first?.words ?? []
    }

    // MARK: Matching

    /// The block's words without its line number.
    private static func words(_ b: GCodeBlock) -> [GCodeBlock.Word] { b.words.filter { $0.letter != "N" } }

    private func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

    /// Exactly these G codes and these other letters, nothing else.
    private static func shape(_ b: GCodeBlock, g: Set<Double>, letters: Set<Character>) -> Bool {
        let w = words(b)
        return Set(w.filter { $0.letter == "G" }.map(\.value)) == g && w.filter { $0.letter == "G" }.count == g.count
            && Set(w.filter { $0.letter != "G" }.map(\.letter)) == letters
            && w.filter { $0.letter != "G" }.count == letters.count
    }

    private func isTopZ(_ b: GCodeBlock) -> Bool { Self.shape(b, g: [53, 0], letters: ["Z"]) && near(b.value("Z"), probe.topZ) }
    private func isParkZ(_ b: GCodeBlock) -> Bool { Self.shape(b, g: [53, 0], letters: ["Z"]) && near(b.value("Z"), probe.parkZ) }
    private static func isG53XY(_ b: GCodeBlock) -> Bool { b.has("G", 53) && (b.value("X") != nil || b.value("Y") != nil) }
    private func isProbeWord(_ b: GCodeBlock) -> Bool { b.has("G", 31) || b.values("G").contains { $0 >= 38 && $0 < 39 } }
    private static func only(_ b: GCodeBlock, _ g: Double) -> Bool { shape(b, g: [g], letters: []) }

    // MARK: Steps

    /// `next` are the blocks after `b`; `spindleOn` is the state before `b`; `motion` the modal motion before it.
    mutating func step(_ b: GCodeBlock, next: ArraySlice<GCodeBlock>, spindleOn: Bool, motion: Int?,
                       issues: inout IssueCollector) -> Effect {
        func error(_ key: String, _ message: String) { issues.add("probe-\(key)", .error, line: b.line, message) }
        for g in b.values("G") where g >= 54 && g <= 59 && g == g.rounded() {
            if [.leaving, .atSpot, .placed, .probed].contains(state) {
                error("offset-change", "A work offset (G\(Int(g))) is selected between the park and the zero: the zero would "
                      + "set an offset the cuts may not run in")
            }
            activeOffset = Int(g)
        }
        // A lift that is not followed by the park was a pause or the footer lifting: back to where it came from.
        if case .lifted(let from) = state, !(Self.isG53XY(b)) && !isTopZ(b) { state = from }

        // Machine-coordinate moves of the sequence.
        if b.has("G", 53) {
            if isTopZ(b) {
                switch state {
                case .needsProbe, .ready: state = .lifted(from: state)
                case .swapped: state = .leaving
                default: break
                }
                return Effect(consumed: 1, positionUnknown: true)
            }
            if Self.isG53XY(b) {
                guard case .lifted = state else {
                    error("g53-xy", "A machine-coordinate X/Y move (G53) that does not start from the traverse height "
                          + "(G53 Z\(NumberFormat.compact(probe.topZ, maxDecimals: profile.decimals)))")
                    return Effect(consumed: 1, positionUnknown: true)
                }
                if Self.shape(b, g: [53, 0], letters: ["X", "Y"]), near(b.value("X"), probe.parkX), near(b.value("Y"), probe.parkY) {
                    state = .parked
                } else {
                    error("park", "The move to the park position is not the machine's park position")
                }
                return Effect(consumed: 1, positionUnknown: true)
            }
            if state == .parked, isParkZ(b) { return Effect(consumed: 1, positionUnknown: true) }
            return Effect()   // any other G53: today's coordinate-shift warning
        }

        if b.value("T") != nil {
            if state == .parked {
                state = .swapReady
                if spindleOn { error("spindle-swap", "The tool is changed with the spindle running") }
            } else {
                error("t", "A tool change (T) outside the park-and-probe sequence: the new tool's Z would not be measured")
            }
        }

        let stops = b.values("M").filter { $0 == 0 || $0 == 1 }
        if !stops.isEmpty {
            switch state {
            case .swapReady:
                state = .swapped
                if spindleOn { error("spindle-swap", "The program stops for the tool swap with the spindle running") }
            case .atSpot:
                state = .placed
                if spindleOn { error("spindle-place", "The program stops to place the touch plate with the spindle running") }
            case .cleared: state = .ready
            default: break
            }
        }

        // The spot rapid.
        if state == .leaving, motionOf(b, motion) == 0, b.value("X") != nil || b.value("Y") != nil {
            guard let spot else { error("spot", "The job has no touch-off spot"); return Effect(consumed: 1) }
            // Exactly G0 X Y: the block is consumed, so any other word in it (a spindle start) would go unchecked.
            if Self.shape(b, g: [0], letters: ["X", "Y"]), near(b.value("X"), spot.x), near(b.value("Y"), spot.y) {
                if activeOffset != 53 + probe.workOffset {
                    error("offset", "The move to the touch-off spot runs in a work offset other than G\(53 + probe.workOffset)")
                }
                state = .atSpot
                return Effect(consumed: 1, xy: spot)
            }
            error("spot", "The move to the touch-off spot must be G0 X Y to the job's touch-off spot, with no other word")
            return Effect(consumed: 1)
        }

        // The probe unit.
        if Self.only(b, 91), state == .placed {
            let rest = Array(next.prefix(2))
            if rest.count == 2, isProbeWord(rest[0]), Self.only(rest[1], 90) {
                checkProbe(rest[0], spindleOn: spindleOn, issues: &issues)
                state = .probed
                return Effect(consumed: 3, afterProbe: true)
            }
        }
        if isProbeWord(b) {
            error("probe-outside", "A probe (G31/G38.2) that is not the touch-plate probe: it must follow the placement stop, "
                  + "between G91 and G90")
            return Effect(consumed: 1, afterProbe: true)
        }

        // The zero.
        let isG10 = b.has("G", 10)
        let isMacro = probe.mach4ZeroMacro.map { b.has("M", Double($0)) } ?? false
        if isG10 || isMacro {
            guard state == .probed else {
                error("zero-outside", "Z is set (G10 or the zero macro) outside the touch-plate sequence")
                return Effect(consumed: 1)
            }
            var consumed = 1
            let v: Double?
            switch probe.controller {
            case .grbl:
                guard isG10, Self.shape(b, g: [10], letters: ["L", "P", "Z"]), b.value("L") == 20 else {
                    error("zero", "The zero after the probe must be G10 L20 P\(probe.workOffset) Z…")
                    return Effect(consumed: 1)
                }
                if b.value("P") != Double(probe.workOffset) {
                    error("zero-offset", "G10 L20 sets offset P\(NumberFormat.compact(b.value("P") ?? 0, maxDecimals: 0)), not "
                          + "the machine's work offset P\(probe.workOffset)")
                }
                v = b.value("Z")
            case .mach4:
                guard isMacro, !isG10, Self.shape(b, g: [], letters: ["M", "P"]) else {
                    error("zero", "On Mach4 the zero after the probe must be the zero macro M\(probe.mach4ZeroMacro ?? 0) P…: "
                          + "Mach4's G10 L20 sets the extended offset G54.1, not this position")
                    return Effect(consumed: 1)
                }
                v = b.value("P")
                if let r = next.first, Self.words(r) == recoveryLine {
                    consumed = 2
                } else {
                    error("recovery", "The zero macro must be followed by the line that restores the modes: "
                          + "G17 G40 G49 G80 G90 G94 … G\(53 + probe.workOffset)")
                }
            }
            if !near(v, plateZ) {
                error("zero-value", "Z is set to \(NumberFormat.compact(v ?? .nan, maxDecimals: profile.decimals)) at the plate, "
                      + "not the plate's top (\(NumberFormat.compact(plateZ, maxDecimals: profile.decimals)))")
            }
            if activeOffset != 53 + probe.workOffset {
                error("offset", "Z is set in a work offset other than G\(53 + probe.workOffset)")
            }
            state = .zeroedAtSpot
            spotGate = true
            return Effect(consumed: consumed, z: plateZ)
        }

        // Moves after the zero.
        let m = motionOf(b, motion)
        let bz = b.value("Z")
        if spotGate {
            if let x = b.value("X"), let s = spot, !near(x, s.x) { spotGate = false }
            if let y = b.value("Y"), let s = spot, !near(y, s.y) { spotGate = false }
            if let z = bz, z < clearZ - tol {
                error("spot-descent", "The tool moves below the plate's clearance at the touch-off spot, where the plate may "
                      + "still lie")
            }
        }
        if state == .zeroedAtSpot, m == 0, let z = bz, z >= clearZ - tol, b.value("X") == nil, b.value("Y") == nil {
            state = .cleared
        }
        if b.has("M", 3) || b.has("M", 4), state != .ready {
            error("spindle-start", "The spindle starts before the touch-plate sequence is complete (the clear move and the "
                  + "removal stop)")
        }
        if let m, [1, 2, 3].contains(m), b.value("X") != nil || b.value("Y") != nil || bz != nil {
            if state != .ready {
                error("cut", "A cut before the new tool's Z is measured and the plate is removed")
            } else if activeOffset != 53 + probe.workOffset {
                error("offset", "A cut runs in a work offset other than the one the touch plate zeroed "
                      + "(G\(53 + probe.workOffset))")
            }
        }
        return Effect()
    }

    private func motionOf(_ b: GCodeBlock, _ modal: Int?) -> Int? {
        b.values("G").last { [0, 1, 2, 3].contains($0) }.map(Int.init) ?? modal
    }

    private func checkProbe(_ b: GCodeBlock, spindleOn: Bool, issues: inout IssueCollector) {
        func error(_ key: String, _ message: String) { issues.add("probe-\(key)", .error, line: b.line, message) }
        let code: Double = probe.controller == .grbl ? 38.2 : 31
        if !Self.shape(b, g: [code], letters: ["Z", "F"]) {
            error("probe-shape", "The probe must be \(probe.controller.probeCode) with a Z distance and a feed only")
        }
        if let z = b.value("Z") {
            if z >= 0 { error("probe-up", "The probe must move down (a negative Z)") }
            if -z > probe.probeTravel + tol { error("probe-travel", "The probe travels further than the machine allows") }
        }
        if let f = b.value("F"), f > probe.probeFeed + feedTol { error("probe-feed", "The probe is faster than the machine allows") }
        if spindleOn { error("spindle-probe", "The probe runs with the spindle on") }
    }
}
