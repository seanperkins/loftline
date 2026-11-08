import CADCore
import Foundation

/// Checks toolpaths against keep-out zones: the tool (its radius plus `margin`) must not come
/// over a zone while lower than the zone's top plus `margin`. Rapids are checked too.
public enum KeepOut {
    public struct Violation: Hashable, Sendable {
        public var toolpathName: String
        public var zoneName: String
        public var isRapid: Bool
        /// Where it happens (material frame).
        public var at: Vec2
    }

    /// Metadata key marking travel that is written as it is (the post's footer, #132): a rapid from below safe Z goes
    /// across where it starts, not after the climb the post adds before the program's own XY rapids.
    public static let asWrittenKey = "travel as written"

    public static func violations(_ toolpaths: [Toolpath], zones: [KeepOutZone], coords: MachineCoordinates,
                                  margin: Double, tolerance: Double) -> [Violation] {
        let usable = zones.filter(\.isUsable)
        guard !usable.isEmpty else { return [] }
        var out: [Violation] = []
        // The program is one move stream: the post travels from one toolpath's last point to
        // the next one's first, so that travel is checked too. After a tool change the XY is
        // unknown (the controller may have moved), so checking restarts there.
        var cur: Vec3?
        var lastTool: UUID?
        for tp in toolpaths where tp.moves.contains(where: { $0.target != nil }) {
            if tp.tool.id != lastTool { cur = nil; lastTool = tp.tool.id }
            let r = tp.tool.radius + max(margin, 0)
            // Zone outlines grown by the tool radius + margin, as machine-frame regions.
            let grown: [(zone: KeepOutZone, region: [[Vec2]], topZ: Double, box: Rect2)] = usable.map { z in
                let region = GeomKernel.offset([Polygon2D.signedArea(z.outline) < 0 ? z.outline.reversed() : z.outline],
                                               by: r, join: .round, arcTolerance: tolerance)
                    .map { $0.map { coords.machineXY($0) } }
                let topZ = coords.z(depth: -(z.height + max(margin, 0)))
                return (z, region, topZ, Rect2(points: region.flatMap { $0 }))
            }
            var reported = Set<UUID>()
            let asWritten = tp.metadata[asWrittenKey] != nil
            for m in tp.moves {
                guard let target = m.target else { continue }
                defer { cur = target }
                guard let from = cur else { continue }
                // The post climbs to safe Z before an XY rapid from below it.
                var pts = polyline(from: from, move: m, tolerance: tolerance)
                if m.isRapid, !asWritten, from.z < coords.safeZ - 1e-9, from.xy.distance(to: target.xy) > 1e-9 {
                    let up = Vec3(from.xy, z: max(coords.safeZ, target.z))
                    pts = [from, up, Vec3(target.xy, z: up.z), target]
                }
                for g in grown where !reported.contains(g.zone.id) {
                    // Every piece is tested against the grown outline exactly, not by sampling points along it:
                    // a move grazing a convex corner crosses the grown region along a chord that can be
                    // shorter than any sampling step.
                    guard let at = zip(pts, pts.dropFirst()).lazy.compactMap({ firstHit($0, $1, region: g.region, box: g.box, topZ: g.topZ) }).first
                    else { continue }
                    reported.insert(g.zone.id)
                    out.append(Violation(toolpathName: tp.name, zoneName: g.zone.name, isRapid: m.isRapid,
                                         at: coords.materialXY(fromMachine: at.xy)))
                }
            }
        }
        return out
    }

    /// The move as a polyline: the end points of a straight move, an arc cut into chords within `tolerance`.
    static func polyline(from a: Vec3, move m: Move, tolerance: Double) -> [Vec3] {
        guard let b = m.target else { return [] }
        switch m {
        case .arcCW(_, let c, _), .arcCCW(_, let c, _):
            let cw: Bool = { if case .arcCW = m { return true } else { return false } }()
            let sweep = Flattening.arcSweep(from: a.xy, to: b.xy, center: c, clockwise: cw)
            let radius = a.xy.distance(to: c)
            let maxStep = radius > tolerance ? 2 * acos(max(-1, 1 - tolerance / radius)) : Double.pi / 2
            let n = min(4000, max(2, Int((abs(sweep) / max(maxStep, 1e-3)).rounded(.up))))
            let a0 = (a.xy - c).angle
            return (0...n).map { k in
                let t = Double(k) / Double(n)
                let ang = a0 + (cw ? -1 : 1) * abs(sweep) * t
                return Vec3(c + Vec2(cos(ang), sin(ang)) * radius, z: a.z + (b.z - a.z) * t)
            }
        default:
            return [a, b]
        }
    }

    /// A point of the straight piece a→b that is over `region` while lower than `topZ`, or nil. The piece is
    /// cut where it crosses the region's edges (and where it passes `topZ`), and the middle of each part is
    /// tested.
    static func firstHit(_ a: Vec3, _ b: Vec3, region: [[Vec2]], box: Rect2, topZ: Double) -> Vec3? {
        guard min(a.z, b.z) < topZ - 1e-9, Rect2(points: [a.xy, b.xy]).intersects(box) else { return nil }
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
        if (a.z < topZ) != (b.z < topZ), a.z != b.z { ts.append((topZ - a.z) / (b.z - a.z)) }
        ts.sort()
        for (t0, t1) in zip(ts, ts.dropFirst()) where t1 - t0 > 1e-12 {
            let tm = (t0 + t1) / 2
            let p = Vec3(a.xy.lerp(to: b.xy, tm), z: a.z + (b.z - a.z) * tm)
            if p.z < topZ - 1e-9, Polygon2D.regionContains(region, p.xy) { return p }
        }
        return nil
    }
}
