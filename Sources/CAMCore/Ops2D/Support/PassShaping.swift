import CADCore
import Foundation

/// One cutting pass along a chain, as monotone pieces of stations (a zig-zag ramp is several
/// pieces going back and forth; the main lap is one piece).
public struct ChainPass: Sendable {
    public var pieces: [[StationPoint]]
    /// Unwrapped parameter where the pass ends (next pass on a closed loop may start here).
    public var endS: Double
    /// The entry ramp goes down steeper than `RampSettings.maxAngle`: the vector is too short for the
    /// ramp even at its lap or leg cap, or the angle is under the 0.5° floor (issue #124).
    public var isSteeperThanMaxAngle = false

    public var points: [CutPoint] {
        var out: [CutPoint] = []
        for piece in pieces {
            for p in piece {
                if let l = out.last, l.xy == p.xy, l.depth == p.depth { continue }
                out.append(p.cutPoint)
            }
        }
        return out
    }
}

/// Builds the depth profile of a pass: plunge or ramp entry, main lap, overcut.
public enum PassShaping {
    /// Upper bound on zig-zag legs per pass (even).
    static let maxZigzagLegs = 200
    /// Upper bound on the laps one smooth or spiral ramp may take (a pathologically tiny loop and a deep pass).
    static let maxRampLaps = 200.0

    /// The warning an operation gives when some pass's ramp is steeper than its maximum angle.
    public static func steepRampWarning(_ ramp: RampSettings) -> String {
        "ramps go down steeper than the \(String(format: "%g", ramp.maxAngle))° maximum angle on some passes "
            + "(the vector is too short, or the angle is under 0.5°); use a plunge, a steeper maximum angle, "
            + "or a shallower pass depth"
    }

    /// Length along the loop of a smooth or spiral descent: at least what was asked, at least what the
    /// angle needs, at most `maxRampLaps` laps.
    private static func descentLength(asked: Double, L: Double, drop: Double, tanA: Double) -> Double {
        min(max(asked, drop / tanA), L * Self.maxRampLaps)
    }

    /// True when a descent of `slope` (depth per unit run) is steeper than the angle the user asked for,
    /// not the clamped one the ramp was built with.
    private static func isSteeper(_ slope: Double, than ramp: RampSettings) -> Bool {
        let requested = ramp.maxAngle <= 0 ? 0 : tan(min(ramp.maxAngle, 89.5) * .pi / 180)
        return slope > requested * (1 + 1e-9)
    }

    /// - Parameters:
    ///   - s0: unwrapped start parameter (closed loops) — 0 for open chains.
    ///   - fromDepth: depth already cut along this chain (ramp start).
    ///   - toDepth: this pass's depth.
    ///   - overcut: extra distance past the start on closed loops.
    ///   - spiralFinish: for spiral ramps, append a flat lap at `toDepth` (last pass).
    public static func pass(on chain: ArcLengthChain, s0: Double, fromDepth: Double, toDepth: Double,
                            ramp: RampSettings, overcut: Double = 0, spiralFinish: Bool = true) -> ChainPass {
        let L = chain.length
        let drop = toDepth - fromDepth
        let tanA = tan(min(max(ramp.maxAngle, 0.5), 89.5) * .pi / 180)
        let flat: (Double) -> Double = { _ in toDepth }
        guard ramp.isEnabled, drop > 1e-9, L > 0 else {
            let end = chain.isClosed ? s0 + L + max(0, overcut) : L
            return ChainPass(pieces: [chain.samples(from: s0, to: end, depth: flat)], endS: end)
        }
        var type = ramp.type
        if !chain.isClosed, type != .zigzag { type = .zigzag }
        switch type {
        case .spiral:
            // At least one lap, and as far round as the maximum angle needs (issue #124); a loop long enough
            // for one lap gets exactly one, as before.
            let length = descentLength(asked: L, L: L, drop: drop, tanA: tanA)
            let helix = chain.samples(from: s0, to: s0 + length) { s in fromDepth + drop * (s - s0) / length }
            var pieces = [helix]
            var end = s0 + length
            if spiralFinish {
                pieces.append(chain.samples(from: end, to: end + L + max(0, overcut), depth: flat))
                end += L + max(0, overcut)
            }
            var pass = ChainPass(pieces: pieces, endS: end)
            pass.isSteeperThanMaxAngle = isSteeper(drop / length, than: ramp)
            return pass
        case .smooth:
            // The asked-for length is cut short at one lap, but the maximum angle is not: a loop shorter than
            // drop / tan(angle) goes round again until the descent is gentle enough (a helix, then one lap flat).
            let lr = descentLength(asked: min(ramp.length, L), L: L, drop: drop, tanA: tanA)
            let end = s0 + L + max(lr, overcut)
            let piece = chain.samples(from: s0, to: end, extraBreaks: [s0 + lr]) { s in
                s < s0 + lr ? fromDepth + drop * (s - s0) / lr : toDepth
            }
            var pass = ChainPass(pieces: [piece], endS: end)
            pass.isSteeperThanMaxAngle = isSteeper(drop / lr, than: ramp)
            return pass
        case .zigzag:
            // A zero or tiny length is floored at the shortest leg that keeps the max angle in
            // two legs (as the smooth ramp floors at drop / tan); legs are capped so a very
            // short open vector cannot turn one pass into thousands of legs.
            let lz = min(max(ramp.length, drop / tanA / 2), L)
            let perLeg = lz * tanA
            // Capped as a Double before the Int conversion, so a vanishing leg cannot overflow it.
            let wanted = max(2, ceil(drop / perLeg - 1e-9))
            var legs = Int(min(wanted, Double(Self.maxZigzagLegs)))
            if legs % 2 == 1 { legs += 1 }
            var pieces: [[StationPoint]] = []
            for k in 0..<legs {
                let d0 = fromDepth + drop * Double(k) / Double(legs)
                let d1 = fromDepth + drop * Double(k + 1) / Double(legs)
                let forward = k % 2 == 0
                let a = forward ? s0 : s0 + lz, b = forward ? s0 + lz : s0
                pieces.append(chain.samples(from: a, to: b) { s in d0 + (d1 - d0) * abs(s - a) / lz })
            }
            let end = chain.isClosed ? s0 + L + max(0, overcut) : L
            pieces.append(chain.samples(from: s0, to: end, depth: flat))
            var pass = ChainPass(pieces: pieces, endS: end)
            pass.isSteeperThanMaxAngle = isSteeper(drop / Double(legs) / lz, than: ramp)
            return pass
        }
    }
}

/// Holding tabs: intervals along a closed loop where the cut is raised to leave a bridge.
public struct TabLayout: Sendable {
    /// Tab centres in [0, length).
    public var centers: [Double]
    /// Half of the raised length along the toolpath (bridge length + tool diameter, halved).
    public var halfWidth: Double
    /// Depth of the tab top.
    public var topDepth: Double
    public var thickness: Double
    public var isTriangular: Bool
    public var loopLength: Double
    /// How many tabs were asked for on this loop (the settings' count, or the anchors given);
    /// fewer in `centers` means some could not be kept apart.
    public var requestedCount: Int

    /// Lays out tabs evenly; `spacing` (if set) overrides the count.
    public init(loopLength L: Double, settings: TabSettings, toolDiameter: Double, cutDepth: Double) {
        loopLength = L
        thickness = max(0, settings.thickness)
        topDepth = cutDepth - thickness
        isTriangular = settings.isTriangular
        halfWidth = max(0, settings.length + toolDiameter) / 2
        var n = settings.countPerPath
        if let sp = settings.spacing, sp > 0 { n = max(1, Int((L / sp).rounded(.down))) }
        requestedCount = max(0, n)
        // Tabs must not overlap: keep at least one raised length of cutting between them.
        if halfWidth > 0 { n = min(n, Int((L / (4 * halfWidth)).rounded(.down))) }
        n = max(0, n)
        centers = (0..<n).map { (Double($0) + 0.5) * L / Double(n) }
    }

    /// User-placed tabs at the given loop parameters (in [0, length)).
    public init(loopLength L: Double, centers: [Double], settings: TabSettings, toolDiameter: Double,
                cutDepth: Double) {
        self.init(loopLength: L, settings: settings, toolDiameter: toolDiameter, cutDepth: cutDepth)
        requestedCount = centers.count
        let wrapped = centers.map { c -> Double in
            let r = L > 0 ? c.truncatingRemainder(dividingBy: L) : 0
            return r < 0 ? r + L : r
        }.sorted()
        // Overlapping tabs would produce crossing rise/drop breaks: keep the first of each cluster.
        var kept: [Double] = []
        for c in wrapped {
            let clash = kept.contains { k in
                let d = abs(c - k)
                return min(d, L - d) < 2 * halfWidth
            }
            if !clash { kept.append(c) }
        }
        self.centers = kept
    }

    /// Raised-depth limit at unwrapped parameter s (nil outside tabs).
    func limit(at s: Double, strict: Bool = false) -> Double? {
        let u = local(s)
        for c in centers {
            var d = abs(u - c)
            d = min(d, loopLength - d)
            if strict ? d < halfWidth - 1e-9 : d <= halfWidth {
                return isTriangular ? topDepth + thickness * d / max(halfWidth, 1e-12) : topDepth
            }
        }
        return nil
    }

    func local(_ s: Double) -> Double {
        let r = s.truncatingRemainder(dividingBy: loopLength)
        return r < 0 ? r + loopLength : r
    }

    /// Tab boundary (and centre) parameters within [lo, hi], unwrapped.
    func breaks(from lo: Double, to hi: Double) -> [(s: Double, kind: Int)] {
        guard loopLength > 0 else { return [] }
        var out: [(Double, Int)] = []
        var lap = (lo / loopLength).rounded(.down) - 1
        while lap * loopLength <= hi + loopLength {
            for c in centers {
                let base = lap * loopLength + c
                for (s, k) in [(base - halfWidth, 0), (base, 1), (base + halfWidth, 2)] where s >= lo && s <= hi {
                    out.append((s, k))
                }
            }
            lap += 1
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Applies the tab limits to a pass (each piece is monotone in s).
    public func apply(to pass: ChainPass, chain: ArcLengthChain) -> ChainPass {
        guard !centers.isEmpty, thickness > 0 else { return pass }
        var out = pass
        out.pieces = pass.pieces.map { piece in
            guard piece.count > 1 else { return piece }
            let descending = piece.last!.s < piece.first!.s
            let asc = descending ? Array(piece.reversed()) : piece
            let shaped = applyAscending(asc, chain: chain)
            return descending ? shaped.reversed() : shaped
        }
        return out
    }

    private func applyAscending(_ piece: [StationPoint], chain: ArcLengthChain) -> [StationPoint] {
        let lo = piece.first!.s, hi = piece.last!.s
        let bks = breaks(from: lo, to: hi)
        // Merge original stations with breakpoints, interpolating depth along s.
        var stations: [(StationPoint, Int)] = piece.map { ($0, -1) }
        var j = 0
        for b in bks {
            while j < piece.count - 1, piece[j + 1].s < b.s { j += 1 }
            let a = piece[j], c = piece[min(j + 1, piece.count - 1)]
            let t = c.s > a.s ? (b.s - a.s) / (c.s - a.s) : 0
            let d = a.depth + (c.depth - a.depth) * min(max(t, 0), 1)
            stations.append((StationPoint(xy: chain.point(at: b.s), s: b.s, depth: d), b.kind))
        }
        stations.sort { $0.0.s < $1.0.s || ($0.0.s == $1.0.s && $0.1 > $1.1) }
        var out: [StationPoint] = []
        for (p, kind) in stations {
            var q = p
            if isTriangular || kind == 1 || kind == -1 {
                if let lim = limit(at: p.s, strict: kind == -1) { q.depth = min(q.depth, lim) }
                out.append(q)
            } else if kind == 0 {
                // Entering a rectangular tab: arrive at full depth, then rise.
                out.append(p)
                q.depth = min(p.depth, topDepth)
                out.append(q)
            } else {
                // Leaving: at tab height, then drop back.
                q.depth = min(p.depth, topDepth)
                out.append(q)
                out.append(p)
            }
        }
        return out
    }
}
