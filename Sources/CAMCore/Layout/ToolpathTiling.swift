import CADCore
import Foundation

/// How to split a job that is larger than the machine into tiles.
public struct TilingSettings: Hashable, Sendable {
    /// Largest tile the machine can reach (document units).
    public var tileWidth: Double
    public var tileHeight: Double
    /// Width of the band along each shared tile edge that both neighbouring tiles cut.
    public var overlap: Double

    public init(tileWidth: Double, tileHeight: Double, overlap: Double = 0) {
        self.tileWidth = tileWidth; self.tileHeight = tileHeight; self.overlap = overlap
    }
}

/// One tile: the part of the job machined with the material in one position.
public struct ToolpathTile: Hashable, Sendable {
    /// 1-based, row by row from the lower-left.
    public var number: Int
    public var column: Int
    public var row: Int
    /// Material area this tile machines (material frame, overlap included). Its lower-left
    /// corner is the tile's X0 Y0.
    public var region: Rect2
    /// Job for this tile: same Z setup, XY origin at the region's lower-left corner.
    public var job: JobSetup
    /// Toolpaths clipped to the region, in the tile job's machine coordinates.
    public var toolpaths: [Toolpath]
}

/// Splits toolpaths into tiles. Cutting moves are clipped to each tile's region; the cutter
/// retracts to safe Z where a cut leaves the region and re-enters with a rapid at safe Z and a
/// plunge at the plunge rate. Edges on the outside of the job are not clipped, so profiles
/// around parts at the material edge are kept. Each tile's G-code is zeroed at the tile's
/// lower-left corner on the material.
public enum ToolpathTiling {
    public struct Cell: Hashable, Sendable {
        public var column: Int
        public var row: Int
        /// Finite region (material frame), overlap included.
        public var region: Rect2
        /// Region used for clipping: outer job edges pushed out so nothing near them is lost.
        public var clip: Rect2
    }

    /// The overlap a grid can use along an axis whose tiles may reach `largest`: less than half of it, so every tile
    /// still advances by more than half its size and the grid never needs more than about twice the tiles it would
    /// without overlap. A larger overlap is ignored (0).
    static func usableOverlap(_ overlap: Double, largest: Double) -> Double {
        overlap > 0 && overlap < largest / 2 ? overlap : 0
    }

    /// The axes along which `settings` asks for an overlap that is ignored (half a tile or more).
    public static func axesIgnoringOverlap(_ s: TilingSettings) -> (x: Bool, y: Bool) {
        guard s.overlap > 0 else { return (false, false) }
        return (usableOverlap(s.overlap, largest: s.tileWidth) == 0, usableOverlap(s.overlap, largest: s.tileHeight) == 0)
    }

    /// How many equal tiles cover `extent` when none may reach further than `largest`, counting the overlap: the
    /// first and the last tile reach half of it into their one neighbour, the ones between into both.
    static func tileCount(extent: Double, largest: Double, overlap: Double) -> Int {
        let plain = max(1, Int((extent / largest - 1e-9).rounded(.up)))
        let overlap = usableOverlap(overlap, largest: largest)
        guard plain > 1, overlap > 0 else { return plain }
        if extent / 2 + overlap / 2 <= largest + 1e-9 { return 2 }
        // Three or more: every interior tile is extent / n + overlap wide.
        return max(3, Int((extent / (largest - overlap) - 1e-9).rounded(.up)))
    }

    /// The tile grid for a job: equal tiles no larger than the requested size, overlap into the neighbours included.
    public static func cells(job: JobSetup, settings s: TilingSettings) -> [Cell] {
        guard s.tileWidth > 0, s.tileHeight > 0 else { return [] }
        let nx = tileCount(extent: job.width, largest: s.tileWidth, overlap: s.overlap)
        let ny = tileCount(extent: job.height, largest: s.tileHeight, overlap: s.overlap)
        let tw = job.width / Double(nx), th = job.height / Double(ny)
        let halfX = usableOverlap(s.overlap, largest: s.tileWidth) / 2, halfY = usableOverlap(s.overlap, largest: s.tileHeight) / 2
        let far = (job.width + job.height) * 10 + 1000
        var out: [Cell] = []
        for r in 0..<ny {
            for c in 0..<nx {
                let x0 = Double(c) * tw, y0 = Double(r) * th
                let lo = Vec2(c == 0 ? x0 : x0 - halfX, r == 0 ? y0 : y0 - halfY)
                let hi = Vec2(c == nx - 1 ? x0 + tw : x0 + tw + halfX, r == ny - 1 ? y0 + th : y0 + th + halfY)
                let clipLo = Vec2(c == 0 ? -far : lo.x, r == 0 ? -far : lo.y)
                let clipHi = Vec2(c == nx - 1 ? far : hi.x, r == ny - 1 ? far : hi.y)
                out.append(Cell(column: c, row: r, region: Rect2(min: lo, max: hi), clip: Rect2(min: clipLo, max: clipHi)))
            }
        }
        return out
    }

    public static func tile(_ toolpaths: [Toolpath], job: JobSetup, units: LengthUnit,
                            settings: TilingSettings) -> [ToolpathTile] {
        let source = MachineCoordinates(job: job)
        return cells(job: job, settings: settings).enumerated().map { i, cell in
            var tj = job
            tj.width = cell.region.width
            tj.height = cell.region.height
            tj.xyOrigin = .lowerLeft
            // The operator zeros XY at the tile corner; the job's datum offset and home were
            // relative to the whole material's origin and would shift every tile.
            tj.datumOffset = nil
            tj.home = .zero
            let tc = MachineCoordinates(job: tj)
            var clipped: [Toolpath] = []
            for tp in toolpaths {
                if let c = clip(tp, to: cell.clip, offset: cell.region.min, source: source, target: tc, units: units) {
                    clipped.append(c)
                } else if let pause = tp.pauseAfter, let op = tp.operationID,
                          let k = clipped.lastIndex(where: { $0.operationID == op }) {
                    // The pause rides on its operation's last toolpath; when this tile cuts none of that one, it goes
                    // after the operation's last toolpath the tile does cut.
                    clipped[k].pauseAfter = pause
                }
            }
            return ToolpathTile(number: i + 1, column: cell.column, row: cell.row, region: cell.region, job: tj,
                                toolpaths: clipped)
        }
    }

    /// The part of `tp` inside `region` (material frame), moved so `offset` is the new XY zero.
    /// nil when nothing is cut inside the region.
    static func clip(_ tp: Toolpath, to region: Rect2, offset: Vec2, source: MachineCoordinates,
                     target: MachineCoordinates, units: LengthUnit) -> Toolpath? {
        let eps = units == .inch ? 1e-5 : 2.5e-4
        let safe = source.safeZ
        let top = source.materialTopZ
        let gap = min(source.job.safeZ, units == .inch ? 0.05 : 1)
        let plunge = max(tp.tool.converted(to: units).plungeRate, eps)
        func mat(_ p: Vec3) -> Vec2 { source.materialXY(fromMachine: p.xy) }
        func out(_ p: Vec2, _ z: Double) -> Vec3 { Vec3(target.machineXY(p - offset), z: z) }

        var moves: [Move] = []
        var at: Vec3?          // last emitted position (target coordinates)
        var cuts = false

        func retract() {
            if let e = at, e.z < safe - eps {
                moves.append(.rapid(to: Vec3(e.xy, z: safe)))
                at = Vec3(e.xy, z: safe)
            }
        }
        /// Moves to `p` (target coordinates) from wherever the tool is, safely.
        func approach(_ p: Vec3, rapidDescent: Bool) {
            if let e = at, e.distance(to: p) <= eps { return }
            if let e = at, e.xy.distance(to: p.xy) <= eps {
                if p.z >= e.z || rapidDescent || p.z >= top { moves.append(.rapid(to: p)) } else { moves.append(.linear(to: p, feed: plunge)) }
                at = p
                return
            }
            retract()
            moves.append(.rapid(to: Vec3(p.xy, z: max(safe, at?.z ?? safe))))
            if rapidDescent || p.z >= top {
                if p.z < safe { moves.append(.rapid(to: p)) }
            } else {
                moves.append(.rapid(to: Vec3(p.xy, z: top + gap)))
                moves.append(.linear(to: p, feed: plunge))
            }
            at = p
        }
        /// Feed segment a→b (source coordinates) clipped to the region.
        func feed(_ a: Vec3, _ b: Vec3, _ f: Double) {
            let pa = mat(a), pb = mat(b)
            guard let (t0, t1) = clipParams(pa, pb, region) else { retract(); return }
            func lerp(_ t: Double) -> Vec3 {
                let p = pa + (pb - pa) * t
                return out(p, a.z + (b.z - a.z) * t)
            }
            let s = lerp(t0), e = lerp(t1)
            approach(s, rapidDescent: false)
            if s.distance(to: e) > eps {
                moves.append(.linear(to: e, feed: f))
                at = e
                cuts = true
            }
            if t1 < 1 - 1e-12 { retract() }
        }

        var cur: Vec3?
        for move in tp.moves {
            switch move {
            case .dwell(let s):
                if let c = cur, region.contains(mat(c)) { moves.append(.dwell(seconds: s)) }
            case .rapid(let b):
                if region.contains(mat(b)) {
                    let p = out(mat(b), b.z)
                    if let e = at, e.xy.distance(to: p.xy) <= eps || (e.z >= safe - eps && p.z >= safe - eps) {
                        // Vertical rapid, or a traverse at a safe height: keep it as it is.
                        moves.append(.rapid(to: p))
                        at = p
                    } else {
                        approach(p, rapidDescent: true)
                    }
                } else {
                    retract()
                }
                cur = b
            case .linear(let b, let f):
                if let a = cur { feed(a, b, f) } else if region.contains(mat(b)) { approach(out(mat(b), b.z), rapidDescent: false) }
                cur = b
            case .arcCW(let b, let c, let f), .arcCCW(let b, let c, let f):
                let cw: Bool = { if case .arcCW = move { return true } else { return false } }()
                guard let a = cur else { cur = b; continue }
                let pts = arcPoints(from: a, to: b, center: c, clockwise: cw, tolerance: max(eps * 20, 1e-4))
                if pts.allSatisfy({ region.contains(mat($0)) }) && region.contains(mat(a)) {
                    let s = out(mat(a), a.z)
                    approach(s, rapidDescent: false)
                    let e = out(mat(b), b.z)
                    let cc = target.machineXY(source.materialXY(fromMachine: c) - offset)
                    moves.append(cw ? .arcCW(to: e, center: cc, feed: f) : .arcCCW(to: e, center: cc, feed: f))
                    at = e
                    cuts = true
                } else {
                    var p = a
                    for q in pts { feed(p, q, f); p = q }
                }
                cur = b
            }
        }
        retract()
        guard cuts else { return nil }
        var t = tp
        t.moves = moves
        return t
    }

    /// Parameter range [t0, t1] of segment a→b inside `r` (Liang–Barsky), nil if outside.
    static func clipParams(_ a: Vec2, _ b: Vec2, _ r: Rect2) -> (Double, Double)? {
        var t0 = 0.0, t1 = 1.0
        let d = b - a
        for (p, q) in [(-d.x, a.x - r.min.x), (d.x, r.max.x - a.x), (-d.y, a.y - r.min.y), (d.y, r.max.y - a.y)] {
            if abs(p) < 1e-15 {
                if q < 0 { return nil }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return nil }
            }
        }
        return (t0, t1)
    }

    /// Points along a (possibly helical) arc, ending at `end`.
    static func arcPoints(from start: Vec3, to end: Vec3, center c: Vec2, clockwise: Bool, tolerance: Double) -> [Vec3] {
        let r = start.xy.distance(to: c)
        guard r > 1e-12 else { return [end] }
        let a0 = atan2(start.y - c.y, start.x - c.x)
        var a1 = atan2(end.y - c.y, end.x - c.x)
        if clockwise {
            while a1 >= a0 - 1e-12 { a1 -= 2 * .pi }
        } else {
            while a1 <= a0 + 1e-12 { a1 += 2 * .pi }
        }
        let sweep = a1 - a0
        let step = 2 * acos(max(-1, min(1, 1 - tolerance / r)))
        let n = max(2, Int((abs(sweep) / max(step, 1e-3)).rounded(.up)))
        return (1...n).map { i in
            if i == n { return end }
            let t = Double(i) / Double(n)
            let ang = a0 + sweep * t
            return Vec3(c.x + r * cos(ang), c.y + r * sin(ang), start.z + (end.z - start.z) * t)
        }
    }
}
