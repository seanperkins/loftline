import CADCore
import Foundation

/// Flattened polylines of a shape, cached by the canvas for drawing and picking.
public struct FlatShape {
    public var shape: Shape
    /// One polyline per path; closed paths do not repeat their first point.
    public var polylines: [(points: [Vec2], closed: Bool)]
    public var bounds: Rect2

    public init(_ shape: Shape, tolerance: Double) {
        self.shape = shape
        polylines = shape.paths.map { ($0.flattened(tolerance: tolerance), $0.isClosed) }
        bounds = Rect2(points: polylines.flatMap(\.points))
    }

    /// Even-odd point-in-shape test across all closed paths.
    public func contains(_ p: Vec2) -> Bool {
        guard bounds.contains(p) else { return false }
        var inside = false
        for pl in polylines where pl.closed { if HitTesting.pointInPolygon(p, pl.points) { inside.toggle() } }
        return inside
    }

    public func distance(to p: Vec2) -> Double {
        polylines.map { HitTesting.distance(from: p, toPolyline: $0.points, closed: $0.closed) }.min() ?? .infinity
    }
}

public enum HitTesting {
    public static func distance(from p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let l2 = ab.lengthSquared
        guard l2 > 0 else { return p.distance(to: a) }
        let t = min(max((p - a).dot(ab) / l2, 0), 1)
        return p.distance(to: a + ab * t)
    }

    public static func distance(from p: Vec2, toPolyline pts: [Vec2], closed: Bool) -> Double {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return p.distance(to: first) }
        var best = Double.infinity
        for i in 0..<(pts.count - 1) { best = min(best, distance(from: p, toSegment: pts[i], pts[i + 1])) }
        if closed { best = min(best, distance(from: p, toSegment: pts[pts.count - 1], first)) }
        return best
    }

    public static func pointInPolygon(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Picks the shape under `p`: the nearest outline within `tolerance` wins; otherwise the
    /// smallest closed shape containing `p`. `candidates` are in draw order (topmost last).
    public static func pick(at p: Vec2, in candidates: [FlatShape], tolerance: Double) -> UUID? {
        var best: (id: UUID, d: Double)?
        for fs in candidates.reversed() where fs.bounds.insetBy(-tolerance).contains(p) {
            let d = fs.distance(to: p)
            if d <= tolerance, d < (best?.d ?? .infinity) { best = (fs.shape.id, d) }
        }
        if let b = best { return b.id }
        let containing = candidates.filter { $0.contains(p) }
        return containing.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.shape.id
    }

    /// Marquee selection. `crossing` (drag right-to-left, CAD convention) selects anything the
    /// rectangle touches; otherwise shapes must lie entirely inside.
    public static func select(in rect: Rect2, candidates: [FlatShape], crossing: Bool) -> [UUID] {
        candidates.filter { fs in
            if crossing {
                guard rect.intersects(fs.bounds) else { return false }
                if fs.polylines.contains(where: { $0.points.contains(where: rect.contains) }) { return true }
                return polylineCrossesRect(fs, rect)
            }
            return rect.contains(fs.bounds.min) && rect.contains(fs.bounds.max)
        }.map(\.shape.id)
    }

    private static func polylineCrossesRect(_ fs: FlatShape, _ r: Rect2) -> Bool {
        let corners = [r.min, Vec2(r.max.x, r.min.y), r.max, Vec2(r.min.x, r.max.y)]
        let edges = (0..<4).map { (corners[$0], corners[($0 + 1) % 4]) }
        for pl in fs.polylines {
            let pts = pl.points
            guard pts.count > 1 else { continue }
            let n = pl.closed ? pts.count : pts.count - 1
            for i in 0..<n {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                if edges.contains(where: { segmentsIntersect(a, b, $0.0, $0.1) }) { return true }
            }
        }
        // Rectangle entirely inside a closed shape's outline is not a "touch".
        return false
    }

    public static func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2) -> Bool {
        func orient(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double { (b - a).cross(c - a) }
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2), d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))
    }
}

/// Grid snapping in document units.
public enum Snapping {
    public static func snap(_ p: Vec2, grid: Double) -> Vec2 {
        guard grid > 0 else { return p }
        return Vec2((p.x / grid).rounded() * grid, (p.y / grid).rounded() * grid)
    }
}
