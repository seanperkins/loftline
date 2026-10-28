import CADCore
import Foundation

/// A generated toolpath for ONE tool. Moves are in machine coordinates.
/// Conventions every generator follows:
///  * the first move is `.rapid` to (startXY, coords.safeZ) — the post adds the initial Z
///    retract before it;
///  * every rapid that changes XY happens at or above `coords.safeZ` (the post also
///    enforces this as a safety net);
///  * the last move leaves the tool at `coords.safeZ`.
public struct Toolpath: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The operation that produced this toolpath (nil for ad-hoc paths).
    public var operationID: UUID?
    public var kind: OperationKind
    /// Copy of the tool, converted to the document's units.
    public var tool: Tool
    public var spindleRPM: Double
    public var moves: [Move]
    /// Free-form diagnostics (e.g. "warning": "flat depth limited").
    public var metadata: [String: String]
    /// The operator stop that follows this toolpath in the program. Set when toolpaths are collected
    /// for export, from the operation's `pauseAfter`; generators leave it nil.
    public var pauseAfter: PauseStep?
    /// Coolant while this toolpath cuts (nil = Off). Set when toolpaths are collected for export, from the
    /// operation's `coolant`; generators leave it nil.
    public var coolant: Coolant?
    /// Depth below the material top (document units) above which the material is already gone
    /// where this toolpath cuts: an operation's start depth, or the carved surface a projected
    /// toolpath follows. The flute check measures the cut from there. Nil = from the top. Set by
    /// `AnyOperation.generate`; generators leave it nil.
    public var clearedDepth: Double?

    public init(id: UUID = UUID(), name: String, operationID: UUID? = nil, kind: OperationKind,
                tool: Tool, spindleRPM: Double? = nil, moves: [Move] = [], metadata: [String: String] = [:]) {
        self.id = id; self.name = name; self.operationID = operationID; self.kind = kind
        self.tool = tool; self.spindleRPM = spindleRPM ?? tool.spindleRPM; self.moves = moves
        self.metadata = metadata
    }

    /// Lowest Z reached by any move (most negative = deepest).
    public var minZ: Double? { moves.compactMap { $0.target?.z }.min() }

    /// Lowest Z any cutting move (feed or arc) ends at; rapids do not count.
    public var minCutZ: Double? {
        moves.compactMap { m -> Double? in if case .rapid = m { return nil }; return m.target?.z }.min()
    }

    /// A cut that goes deeper than the tool's flutes: the shank then rubs the wall above them,
    /// which burns the material and can snap the bit. `depth` is the deepest cut below the
    /// material top, `cleared` how much of that was already gone (`clearedDepth`), `flute` the
    /// flute length; all in `units`.
    public struct FluteOverrun: Hashable, Sendable {
        public var depth: Double
        public var cleared: Double
        public var flute: Double
        public var toolName: String
        public var units: LengthUnit

        /// The wording every surface shows, with both numbers and the tool, for the checks that run on the
        /// live tool name (the export validator).
        public var description: String { text(tool: toolName) }

        /// The same without the tool: what is stored with a calculated toolpath (`metadata["warning"]`). A
        /// rename in the Tool Database is written into the toolpath in place and is not a recalculation, so
        /// a name in stored text would go stale (issue #60); the step the note is shown under names the tool.
        public var note: String { text(tool: nil) }

        private func text(tool: String?) -> String {
            let u = units.abbreviation
            let cut = cleared > 0
                ? "cuts \(f(depth - cleared)) \(u) deeper than the \(f(cleared)) \(u) already cleared"
                : "cuts \(f(depth)) \(u) below the material top"
            let named = tool.map { " (\($0))" } ?? ""
            return "\(cut) with a \(f(flute)) \(u) flute\(named); the shank rubs the wall above the flutes"
        }

        private func f(_ v: Double) -> String { Self.text(v, units: units) }

        /// The digits a flute length or depth is shown with, everywhere it is shown.
        public static func text(_ length: Double, units: LengthUnit) -> String {
            String(format: units == .inch ? "%.4f" : "%.3f", length)
        }
    }

    /// How far the deepest cutting move goes below the material already cleared above it (or the
    /// material top): what the tool's flutes must span. Nil without a cutting move.
    public func fluteReach(coords: MachineCoordinates) -> Double? {
        minCutZ.map { coords.depth(ofMachineZ: $0) - max(0, clearedDepth ?? 0) }
    }

    /// The overrun when the flute reach is more than the tool's flute length; nil when the flute
    /// length is unknown or long enough. `coords` and `units` are the frame the moves are in; the
    /// tool's flute length is converted to `units` before comparing.
    public func cutBeyondFlute(coords: MachineCoordinates, units: LengthUnit, tolerance: Double) -> FluteOverrun? {
        guard let flute = tool.converted(to: units).fluteLength, flute > 0, let reach = fluteReach(coords: coords),
              reach > flute + tolerance else { return nil }
        let cleared = max(0, clearedDepth ?? 0)
        return FluteOverrun(depth: reach + cleared, cleared: cleared, flute: flute, toolName: tool.name, units: units)
    }

    /// XY bounds of everything the moves reach, including the bulge of arcs (the quadrant points
    /// an arc passes through). Used to decide whether two toolpaths can be reordered safely, so
    /// it must never be smaller than the truth.
    public var xyBounds: Rect2 {
        var pts: [Vec2] = []
        var pos: Vec2?
        for m in moves {
            switch m {
            case .arcCW(let p, let c, _), .arcCCW(let p, let c, _):
                if let s = pos {
                    let cw: Bool = { if case .arcCW = m { return true } else { return false } }()
                    let r = s.distance(to: c)
                    let sweep = Flattening.arcSweep(from: s, to: p.xy, center: c, clockwise: cw)
                    let a0 = (s - c).angle
                    for k in 0..<4 {
                        let a = Double(k) * .pi / 2
                        var d = (a - a0).truncatingRemainder(dividingBy: 2 * .pi)   // CCW offset from the start
                        if d < 0 { d += 2 * .pi }
                        let inside = d < 1e-12 || (sweep >= 0 ? d <= sweep : 2 * .pi - d <= -sweep)
                        if inside { pts.append(c + Vec2(cos(a), sin(a)) * r) }
                    }
                }
                pts.append(p.xy)
                pos = p.xy
            case .rapid(let p), .linear(let p, _):
                pts.append(p.xy)
                pos = p.xy
            case .dwell:
                break
            }
        }
        return Rect2(points: pts)
    }
}
