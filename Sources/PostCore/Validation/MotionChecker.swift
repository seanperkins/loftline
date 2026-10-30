import CADCore
import CAMCore
import Foundation

/// Machine envelope and per-move safety rules, expressed in one unit system. Shared by the
/// toolpath and G-code validators so both enforce exactly the same rules.
struct MotionChecker {
    let coords: MachineCoordinates
    let limits: MachineLimits
    let maxFeed: Double
    let units: LengthUnit
    let eps: Double
    /// Compare the travel in `finish()`: only for the written program, which holds every move the machine makes (the move
    /// home, lift-overs, the raised approach, the touch-plate clearance), so the toolpath pass leaves it to that one (#119).
    let checksTravel: Bool

    var issues = IssueCollector()
    private var minP = Vec3(.infinity, .infinity, .infinity)
    private var maxP = Vec3(-.infinity, -.infinity, -.infinity)
    /// The hole the tool is standing in: the XY of the straight-down feed that cut it and the deepest Z
    /// the tool has fed to there. Kept through Z-only rapids; dropped by any XY move, any other feed,
    /// and `leaveHole()`. A rapid back down into it, stopping at or above its bottom, only moves through
    /// air, which is how peck drilling re-enters every hole. One slot is enough: nothing returns to a
    /// hole after visiting another, and the old warning is the safe answer if something does.
    private var hole: (xy: Vec2, z: Double)?

    /// `job` is in `jobUnits`; everything is converted to `units`.
    init(profile: PostProfile, job: JobSetup, jobUnits: LengthUnit, units: LengthUnit, checksTravel: Bool) {
        self.units = units
        self.checksTravel = checksTravel
        coords = MachineCoordinates(job: job.scaled(by: jobUnits.factor(to: units)))
        let f = profile.units.factor(to: units)
        limits = MachineLimits(xTravel: profile.limits.xTravel * f, yTravel: profile.limits.yTravel * f,
                               zTravel: profile.limits.zTravel * f,
                               maxSpoilboardCut: profile.limits.maxSpoilboardCut * f)
        maxFeed = profile.maxFeed * f
        eps = units == .inch ? 0.0005 : 0.01
    }

    var topZ: Double { coords.materialTopZ }
    var safeZ: Double { coords.safeZ }
    /// Deepest machine Z allowed: material bottom minus the permitted spoilboard cut.
    var allowedMinZ: Double { coords.materialBottomZ - limits.maxSpoilboardCut }

    private func f(_ v: Double) -> String { NumberFormat.fixed(v, decimals: units == .inch ? 4 : 3) }
    /// Forget the hole: the caller saw something that may have changed the bit or the frame (the
    /// G-code check: any block that is not a plain move; the toolpath check: a stop or a dwell).
    mutating func leaveHole() { hole = nil }

    // MARK: Rules

    /// `xyMove`: the rapid changes (or may change, when the start XY is unknown) X/Y.
    mutating func rapid(from start: Vec3?, to target: Vec3, xyMove: Bool, line: Int?) {
        if xyMove {
            hole = nil
            guard let s = start else {
                issues.add("rapid-unknown-z", .warning, line: line,
                           "Rapid XY move before the Z height is known; retract to safe Z first")
                visit(target, line: line)
                return
            }
            let low = min(s.z, target.z)
            if low < topZ - eps {
                issues.add("rapid-in-material", .error, line: line,
                           "Rapid XY move inside the material at Z\(f(low)) (material top Z\(f(topZ)))")
            } else if low < safeZ - eps {
                issues.add("rapid-below-safe", .warning, line: line,
                           "Rapid XY move below safe Z (Z\(f(low)) < Z\(f(safeZ)))")
            }
        } else if let s = start, target.z < s.z - eps, target.z < topZ - eps,
                  !(hole.map { $0.xy.distance(to: target.xy) <= eps && target.z >= $0.z } ?? false) {
            // Not a re-entry into the hole this tool has just drilled (a NaN coordinate compares false
            // and so is never one).
            issues.add("rapid-plunge", .warning, line: line,
                       "Rapid plunge below the material top to Z\(f(target.z)); use a feed move")
        }
        visit(target, line: line)
    }

    /// `startKnown`: the start XY is a position the program set, not a guess for a program that has
    /// not named X and Y yet; only a feed from a known XY can drill a hole the checker remembers.
    mutating func feedMove(from start: Vec3?, path: [Vec3], feed: Double?, spindleOn: Bool, line: Int?,
                           startKnown: Bool) {
        guard let feed else {
            issues.add("feed-missing", .error, line: line, "Feed move without a feed rate (F)")
            hole = nil
            path.forEach { visit($0, line: line) }
            return
        }
        if feed <= 0 {
            issues.add("feed-zero", .error, line: line, "Feed move with a zero or negative feed rate")
        } else if feed > maxFeed + eps {
            issues.add("feed-high", .warning, line: line,
                       "Feed rate F\(NumberFormat.compact(feed, maxDecimals: 1)) exceeds the machine maximum \(NumberFormat.compact(maxFeed, maxDecimals: 1))")
        }
        let low = ([start?.z].compactMap { $0 } + path.map(\.z)).min() ?? .infinity
        if !spindleOn, low < topZ - eps {
            issues.add("spindle-off", .error, line: line, "Cutting move with the spindle off (no M3 before cutting)")
        }
        if startKnown, feed > 0, let s = start, low < s.z - eps,
           path.allSatisfy({ $0.xy.distance(to: s.xy) <= eps }) {
            // A plunge from a known XY drills the hole the tool is in, or deepens it (keeping the XY
            // it was first drilled at, so a run of sub-eps steps cannot walk the claim sideways).
            if let h = hole, h.xy.distance(to: s.xy) <= eps {
                hole = (h.xy, min(h.z, low))
            } else {
                hole = (s.xy, low)
            }
        } else {
            hole = nil   // sideways, upward, from nowhere known, or a feed that cannot run
        }
        path.forEach { visit($0, line: line) }
    }

    mutating func rpm(_ s: Double, min lo: Double, max hi: Double, line: Int?) {
        if s < lo - 1e-9 || s > hi + 1e-9 {
            issues.add("rpm-range", .error, line: line,
                       "Spindle speed S\(NumberFormat.compact(s, maxDecimals: 0)) outside \(NumberFormat.compact(lo, maxDecimals: 0))–\(NumberFormat.compact(hi, maxDecimals: 0)) RPM")
        }
    }

    /// Depth check + travel extents for a reached point.
    mutating func visit(_ p: Vec3, line: Int?) {
        if p.z < allowedMinZ - eps {
            issues.add("too-deep", .error, line: line,
                       "Cut to Z\(f(p.z)) is below the allowed depth Z\(f(allowedMinZ)) (material bottom Z\(f(coords.materialBottomZ)) minus \(f(limits.maxSpoilboardCut)) spoilboard allowance)")
        }
        minP = Vec3(min(minP.x, p.x), min(minP.y, p.y), min(minP.z, p.z))
        maxP = Vec3(max(maxP.x, p.x), max(maxP.y, p.y), max(maxP.z, p.z))
    }

    /// Keeps the travel `other` has seen, scaled into this checker's units: a program that switches units mid-way is still
    /// checked as one span (#120).
    mutating func carryExtents(from other: MotionChecker, scale f: Double) {
        guard other.minP.x.isFinite else { return }
        minP = Vec3(other.minP.x * f, other.minP.y * f, other.minP.z * f)
        maxP = Vec3(other.maxP.x * f, other.maxP.y * f, other.maxP.z * f)
    }

    /// Travel checks; call once after all moves (#119, spec docs/specs/2026-10-30-travel-checks-design.md).
    /// - X and Y: the program's zero (where the operator sets it, so a point the machine reaches) and every move fit one
    ///   travel-sized window, whatever the XY origin: `max(maxX, 0) − min(minX, 0)`.
    /// - Z: the program's own span is an error; the stock plus the highest Z (and any cut below the stock) is a warning, since
    ///   whether the tip must reach the spoilboard depends on the bit's stick-out.
    mutating func finish() {
        guard checksTravel, minP.x.isFinite else { return }
        let u = units.abbreviation
        for (axis, lo, hi, travel) in [("X", min(minP.x, 0), max(maxP.x, 0), limits.xTravel),
                                       ("Y", min(minP.y, 0), max(maxP.y, 0), limits.yTravel)] where hi - lo > travel + eps {
            issues.add("travel-\(axis)", .error, line: nil,
                       "\(axis) travel \(f(hi - lo)) \(u) exceeds the machine's \(axis) travel \(f(travel)) \(u) (the program's zero "
                           + "and its moves span \(axis)\(f(lo)) to \(axis)\(f(hi)))")
        }
        if maxP.z - minP.z > limits.zTravel + eps {
            issues.add("travel-Z", .error, line: nil,
                       "Z travel \(f(maxP.z - minP.z)) \(u) exceeds the machine's Z travel \(f(limits.zTravel)) \(u)")
            return
        }
        let bottom = min(minP.z, coords.materialBottomZ)
        if maxP.z - bottom > limits.zTravel + eps {
            issues.add("z-envelope", .warning, line: nil,
                       "\(GCodeValidator.zEnvelopePrefix) the program reaches (Z\(f(bottom)) to Z\(f(maxP.z)): \(f(maxP.z - bottom)) \(u)) "
                           + "is more than the machine's Z travel \(f(limits.zTravel)) \(u): lower Home Z and Safe Z in Job Setup, and "
                           + "check clamp and touch-plate heights.")
        }
    }
}
