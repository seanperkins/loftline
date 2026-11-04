import CADCore
import Foundation

/// Re-routes toolpaths over keep-out zones marked "lift over" (toolpaths-2d round 2).
///
/// Wherever the tool (radius + margin) would be over such a zone below its top (+ margin), the
/// move is cut there: the tool retracts straight up to the clearance height, rapids across
/// above the zone, rapids down to just above the material top and plunges back to the cut at
/// the plunge rate. Cutting moves inside the zone are dropped, so material under the zone is
/// left uncut. Rapids that would pass over a zone too low are raised to the clearance height.
public enum KeepOutAvoidance {
    public struct Result: Sendable {
        public var toolpaths: [Toolpath]
        /// Number of times any toolpath was lifted over a zone.
        public var lifts: Int
    }

    public static func apply(_ toolpaths: [Toolpath], zones: [KeepOutZone], coords: MachineCoordinates,
                             margin: Double, tolerance: Double) -> Result {
        let active = zones.filter { $0.liftOver == true && $0.outline.count > 2 }
        guard !active.isEmpty else { return Result(toolpaths: toolpaths, lifts: 0) }
        let m = max(margin, 0)
        let clearZ = max(coords.safeZ, active.map { coords.z(aboveTop: $0.height + 2 * m) }.max() ?? coords.safeZ)
        let topZ = active.map { coords.z(aboveTop: $0.height + m) }.max() ?? coords.safeZ
        var total = 0
        let out = toolpaths.map { tp -> Toolpath in
            let r = tp.tool.radius + m + 4 * max(tolerance, 1e-6) // a hair wider than the export check
            let loops = active.map { z -> [Vec2] in
                let o = z.outline.map { coords.machineXY($0) }
                return Polygon2D.signedArea(o) < 0 ? o.reversed() : o
            }
            let region = GeomKernel.offset(loops, by: r, join: .round, arcTolerance: tolerance)
            guard !region.isEmpty else { return tp }
            var router = Router(region: region, box: Rect2(points: region.flatMap { $0 }), topZ: topZ, clearZ: clearZ,
                                approachZ: coords.z(aboveTop: m), plunge: tp.tool.plungeRate,
                                tolerance: tolerance)
            let moves = router.route(tp.moves)
            guard router.lifts > 0 || router.raisedRapids > 0 else { return tp }
            total += router.lifts + router.raisedRapids
            var copy = tp
            copy.moves = moves
            copy.metadata["keep-out lifts"] = String(router.lifts + router.raisedRapids)
            return copy
        }
        return Result(toolpaths: out, lifts: total)
    }

    /// Raises the travel between consecutive toolpaths (the post's rapid from one toolpath's
    /// last point to the next one's first point, same tool) over lift-over zones that are taller
    /// than that travel. `apply` only sees one operation at a time, so this runs on the final,
    /// ordered list just before posting. After a tool change the position is unknown (the
    /// controller may have moved), so that travel is left alone; `KeepOut.violations` does the same.
    public static func link(_ toolpaths: [Toolpath], zones: [KeepOutZone], coords: MachineCoordinates,
                            margin: Double, tolerance: Double) -> [Toolpath] {
        let active = zones.filter { $0.liftOver == true && $0.outline.count > 2 }
        guard !active.isEmpty else { return toolpaths }
        let m = max(margin, 0)
        let clearZ = max(coords.safeZ, active.map { coords.z(aboveTop: $0.height + 2 * m) }.max() ?? coords.safeZ)
        let topZ = active.map { coords.z(aboveTop: $0.height + m) }.max() ?? coords.safeZ
        let loops = active.map { z -> [Vec2] in
            let o = z.outline.map { coords.machineXY($0) }
            return Polygon2D.signedArea(o) < 0 ? o.reversed() : o
        }
        var out = toolpaths
        var last: (end: Vec3, tool: UUID)?
        for i in out.indices {
            let tp = out[i]
            guard let first = tp.moves.first(where: { $0.target != nil })?.target,
                  let end = tp.moves.last(where: { $0.target != nil })?.target else { continue }
            defer { last = (end, tp.tool.id) }
            guard let prev = last, prev.tool == tp.tool.id, prev.end.xy.distance(to: first.xy) > 1e-9 else { continue }
            let r = tp.tool.radius + m + 4 * max(tolerance, 1e-6)
            let region = GeomKernel.offset(loops, by: r, join: .round, arcTolerance: tolerance)
            guard !region.isEmpty else { continue }
            var router = Router(region: region, box: Rect2(points: region.flatMap { $0 }), topZ: topZ, clearZ: clearZ,
                                approachZ: coords.z(aboveTop: m), plunge: tp.tool.plungeRate, tolerance: tolerance)
            // The post climbs to safe Z before moving XY when it is lower.
            let travelZ = max(prev.end.z, coords.safeZ)
            let routed = router.route([.rapid(to: prev.end), .rapid(to: Vec3(prev.end.xy, z: travelZ)), .rapid(to: first)])
            guard router.raisedRapids > 0 else { continue }
            var lead: [Move] = []
            var at = prev.end
            for mv in routed.dropFirst() {
                guard let t = mv.target, t.distance(to: at) > 1e-9, t.distance(to: first) > 1e-9 else { continue }
                lead.append(mv); at = t
            }
            out[i].moves = lead + tp.moves
            let n = Int(tp.metadata["keep-out lifts"] ?? "0") ?? 0
            out[i].metadata["keep-out lifts"] = String(n + router.raisedRapids)
        }
        return out
    }

    /// Clearance height above the material top used to lift over these zones (highest
    /// lift-over top + 2 × margin, the height `apply` and `link` travel at); nil when no zone
    /// is marked lift-over.
    public static func clearanceHeight(zones: [KeepOutZone], margin: Double) -> Double? {
        zones.filter { $0.liftOver == true && $0.outline.count > 2 }.map { $0.height + 2 * max(margin, 0) }.max()
    }

    /// Raises the travel after the last toolpath (the post footer's move home: `points`, in
    /// order, machine frame) over lift-over zones that are taller than it. The lifted travel is
    /// appended to the last toolpath and ends where the footer would put the tool, so the
    /// footer's own moves then go nowhere; it never descends inside a zone.
    public static func linkTravel(after toolpaths: [Toolpath], through points: [Vec3], zones: [KeepOutZone],
                                  coords: MachineCoordinates, margin: Double, tolerance: Double) -> [Toolpath] {
        let active = zones.filter { $0.liftOver == true && $0.outline.count > 2 }
        guard !active.isEmpty, !points.isEmpty,
              let i = toolpaths.lastIndex(where: { $0.moves.contains { $0.target != nil } }),
              let end = toolpaths[i].moves.last(where: { $0.target != nil })?.target else { return toolpaths }
        let m = max(margin, 0)
        let clearZ = max(coords.safeZ, active.map { coords.z(aboveTop: $0.height + 2 * m) }.max() ?? coords.safeZ)
        let topZ = active.map { coords.z(aboveTop: $0.height + m) }.max() ?? coords.safeZ
        let loops = active.map { z -> [Vec2] in
            let o = z.outline.map { coords.machineXY($0) }
            return Polygon2D.signedArea(o) < 0 ? o.reversed() : o
        }
        let tp = toolpaths[i]
        let region = GeomKernel.offset(loops, by: tp.tool.radius + m + 4 * max(tolerance, 1e-6), join: .round,
                                       arcTolerance: tolerance)
        guard !region.isEmpty else { return toolpaths }
        var router = Router(region: region, box: Rect2(points: region.flatMap { $0 }), topZ: topZ, clearZ: clearZ,
                            approachZ: coords.z(aboveTop: m), plunge: tp.tool.plungeRate, tolerance: tolerance)
        let routed = router.route([.rapid(to: end)] + points.map { .rapid(to: $0) })
        guard router.raisedRapids > 0 else { return toolpaths }
        var tail: [Move] = []
        var at = end
        for mv in routed.dropFirst() {
            guard let t = mv.target, t.distance(to: at) > 1e-9 else { continue }
            tail.append(mv); at = t
        }
        var out = toolpaths
        out[i].moves += tail
        let n = Int(tp.metadata["keep-out lifts"] ?? "0") ?? 0
        out[i].metadata["keep-out lifts"] = String(n + router.raisedRapids)
        return out
    }

    struct Router {
        let region: [[Vec2]]
        let box: Rect2
        let topZ: Double
        let clearZ: Double
        let approachZ: Double
        let plunge: Double
        let tolerance: Double
        var lifts = 0
        var raisedRapids = 0
        private var out: [Move] = []
        /// Where the tool really is (lifted to clearZ after a lift).
        private var cur: Vec3?
        /// Where the original program would be: the previous move's own target. Moves are
        /// re-routed from here, never from the lifted `cur`, so a cut after a lift resumes at
        /// its real start and depth instead of ramping down from the clearance height.
        private var prev: Vec3?

        init(region: [[Vec2]], box: Rect2, topZ: Double, clearZ: Double, approachZ: Double, plunge: Double,
             tolerance: Double) {
            self.region = region; self.box = box; self.topZ = topZ; self.clearZ = clearZ
            self.approachZ = approachZ; self.plunge = plunge; self.tolerance = tolerance
        }

        mutating func route(_ moves: [Move]) -> [Move] {
            out = []; cur = nil; prev = nil
            for mv in moves {
                guard let target = mv.target else { out.append(mv); continue }
                guard let from = prev else {
                    // Where the tool comes from is not known here; an opening move that lands over a zone below its top
                    // is raised to the clearance height, so the tool never starts inside the zone (and then lifts
                    // straight up through it). The moves after it travel on from up there.
                    if target.z < topZ - 1e-9, Polygon2D.regionContains(region, target.xy) {
                        let up = Vec3(target.xy, z: max(target.z, clearZ))
                        out.append(.rapid(to: up)); cur = up
                        raisedRapids += 1
                    } else {
                        out.append(mv); cur = target
                    }
                    prev = target
                    continue
                }
                defer { prev = target }
                if mv.isRapid {
                    rapid(from: from, to: target)
                } else if mv.isArc {
                    if crosses(arcPoints(from: from, move: mv)) {
                        let pts = arcPoints(from: from, move: mv)
                        for (a, b) in zip(pts, pts.dropFirst()) { cut(from: a, to: b, feed: mv.feed ?? plunge) }
                    } else {
                        emitFromCurrent(to: from); out.append(mv); cur = target
                    }
                } else {
                    cut(from: from, to: target, feed: mv.feed ?? plunge)
                }
            }
            // Ending lifted over a zone: the next toolpath's first rapid would descend from here
            // over the zone, so travel back above the start (outside the zone) and finish at the
            // original last height there.
            if let c = cur, let last = moves.last(where: { $0.target != nil })?.target, c.distance(to: last) > 1e-9,
               let first = moves.first(where: { $0.target != nil })?.target,
               !Polygon2D.regionContains(region, first.xy) {
                if c.xy.distance(to: first.xy) > 1e-9 { out.append(.rapid(to: Vec3(first.xy, z: c.z))) }
                if last.z < c.z { out.append(.rapid(to: Vec3(first.xy, z: last.z))) }
                cur = Vec3(first.xy, z: min(c.z, last.z))
            }
            return out
        }

        /// True when some piece of the polyline is over the region below the zone top.
        private func crosses(_ pts: [Vec3]) -> Bool {
            zip(pts, pts.dropFirst()).contains { a, b in !insideIntervals(a, b).isEmpty }
        }

        /// Parameter intervals of a→b that are over the grown region with the tool below topZ.
        private func insideIntervals(_ a: Vec3, _ b: Vec3) -> [(Double, Double)] {
            guard min(a.z, b.z) < topZ - 1e-9 else { return [] }
            let seg = Rect2(points: [a.xy, b.xy])
            guard seg.intersects(box) else { return [] }
            var ts: [Double] = [0, 1]
            let d = b.xy - a.xy
            for loop in region {
                for i in 0..<loop.count {
                    let p = loop[i], q = loop[(i + 1) % loop.count]
                    let e = q - p
                    let den = d.cross(e)
                    guard abs(den) > 1e-15 else { continue }
                    let w = p - a.xy
                    let t = w.cross(e) / den, u = w.cross(d) / den
                    if t > 0, t < 1, u >= 0, u <= 1 { ts.append(t) }
                }
            }
            ts.sort()
            var res: [(Double, Double)] = []
            for (t0, t1) in zip(ts, ts.dropFirst()) where t1 - t0 > 1e-12 {
                let tm = (t0 + t1) / 2
                let zm = a.z + (b.z - a.z) * tm
                guard zm < topZ - 1e-9, Polygon2D.regionContains(region, a.xy.lerp(to: b.xy, tm)) else { continue }
                if let last = res.last, abs(last.1 - t0) < 1e-12 { res[res.count - 1].1 = t1 } else { res.append((t0, t1)) }
            }
            return res
        }

        private func point(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 {
            Vec3(a.xy.lerp(to: b.xy, t), z: a.z + (b.z - a.z) * t)
        }

        /// The tool is lifted (at clearZ somewhere) when `cur` differs from where the next cut
        /// starts: travel there above everything and plunge back down.
        private mutating func emitFromCurrent(to start: Vec3) {
            guard let c = cur, c.distance(to: start) > 1e-9 else { return }
            if c.xy.distance(to: start.xy) > 1e-9 {
                if c.z < clearZ { out.append(.rapid(to: Vec3(c.xy, z: clearZ))) }
                out.append(.rapid(to: Vec3(start.xy, z: clearZ)))
            }
            if approachZ > start.z, approachZ < clearZ { out.append(.rapid(to: Vec3(start.xy, z: approachZ))) }
            out.append(.linear(to: start, feed: plunge))
            cur = start
        }

        private mutating func cut(from a: Vec3, to b: Vec3, feed: Double) {
            let inside = insideIntervals(a, b)
            if inside.isEmpty {
                emitFromCurrent(to: a)
                out.append(.linear(to: b, feed: feed)); cur = b
                return
            }
            var t = 0.0
            for (t0, t1) in inside {
                if t0 > t + 1e-12 {
                    emitFromCurrent(to: point(a, b, t))
                    let p = point(a, b, t0)
                    out.append(.linear(to: p, feed: feed)); cur = p
                }
                // Lift: straight up, then the next cut (or the end of the move) travels over.
                if let c = cur, c.z < clearZ {
                    out.append(.rapid(to: Vec3(c.xy, z: clearZ)))
                    cur = Vec3(c.xy, z: clearZ)
                    lifts += 1
                }
                t = t1
            }
            if t < 1 - 1e-12 {
                emitFromCurrent(to: point(a, b, t))
                out.append(.linear(to: b, feed: feed)); cur = b
            } else {
                // The move ends inside the zone: stay lifted above its end.
                let end = Vec3(b.xy, z: clearZ)
                if let c = cur, c.xy.distance(to: end.xy) > 1e-9 { out.append(.rapid(to: end)) }
                cur = end
            }
        }

        private mutating func rapid(from a: Vec3, to b: Vec3) {
            let start = cur ?? a
            let endInside = b.z < topZ - 1e-9 && Polygon2D.regionContains(region, b.xy)
            if !endInside, insideIntervals(start, b).isEmpty {
                out.append(.rapid(to: b)); cur = b
                return
            }
            if start.z < clearZ - 1e-9 {
                out.append(.rapid(to: Vec3(start.xy, z: clearZ)))
                raisedRapids += 1
            }
            var p = Vec3(start.xy, z: max(start.z, clearZ))
            if p.xy.distance(to: b.xy) > 1e-9 {
                p = Vec3(b.xy, z: p.z)
                out.append(.rapid(to: p))
            }
            // Never descend into a zone; a later move travels on from up here.
            if !endInside, p.distance(to: b) > 1e-9 { out.append(.rapid(to: b)); p = b }
            cur = p
        }

        private func arcPoints(from a: Vec3, move m: Move) -> [Vec3] {
            guard let b = m.target else { return [a] }
            guard case let (c, cw)? = {
                switch m {
                case .arcCW(_, let c, _): return (c, true)
                case .arcCCW(_, let c, _): return (c, false)
                default: return nil
                }
            }() else { return [a, b] }
            let sweep = abs(Flattening.arcSweep(from: a.xy, to: b.xy, center: c, clockwise: cw))
            let radius = a.xy.distance(to: c)
            let step = radius > tolerance ? 2 * acos(max(-1, 1 - tolerance / radius)) : sweep
            let n = max(2, Int((sweep / max(step, 1e-6)).rounded(.up)))
            let a0 = (a.xy - c).angle
            return (0...n).map { k in
                if k == n { return b }
                let t = Double(k) / Double(n)
                let ang = a0 + (cw ? -1 : 1) * sweep * t
                return Vec3(c + Vec2(cos(ang), sin(ang)) * radius, z: a.z + (b.z - a.z) * t)
            }
        }
    }
}
