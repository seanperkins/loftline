import CADCore
import Foundation

/// Arc helpers shared by the post (linearisation, time estimate) and the validator. Public for `points` alone, which the MCP
/// server's 2D picture draws arcs with.
public enum ArcGeometry {
    /// Signed XY sweep in radians (negative = clockwise); start == end is a full circle.
    static func sweep(from start: Vec2, to end: Vec2, center: Vec2, clockwise: Bool) -> Double {
        Flattening.arcSweep(from: start, to: end, center: center, clockwise: clockwise)
    }

    /// 3D length of a (possibly helical) arc.
    static func length(from start: Vec3, to end: Vec3, center: Vec2, clockwise: Bool) -> Double {
        let r = start.xy.distance(to: center)
        let planar = abs(sweep(from: start.xy, to: end.xy, center: center, clockwise: clockwise)) * r
        let dz = end.z - start.z
        return (planar * planar + dz * dz).squareRoot()
    }

    /// Points along the arc (excluding `start`, including `end`) with chordal error <= `tolerance`.
    /// Z is interpolated linearly with the angle (helix).
    public static func points(from start: Vec3, to end: Vec3, center: Vec2, clockwise: Bool,
                       tolerance: Double) -> [Vec3] {
        let r = start.xy.distance(to: center)
        guard r > 1e-12 else { return [end] }
        let total = sweep(from: start.xy, to: end.xy, center: center, clockwise: clockwise)
        guard total.isFinite, r.isFinite, end.isFinite else { return [end] }
        let tol = min(max(tolerance, 1e-9), r)
        let maxStep = 2 * acos(1 - tol / r)
        let n = max(1, Int((abs(total) / max(maxStep, 1e-6)).rounded(.up)))
        let a0 = (start.xy - center).angle
        // Interpolate the radius too so slightly inconsistent arcs still end exactly at `end`.
        let r1 = end.xy.distance(to: center)
        var out: [Vec3] = []
        out.reserveCapacity(n)
        for i in 1..<n {
            let t = Double(i) / Double(n)
            let a = a0 + total * t
            let rr = r + (r1 - r) * t
            out.append(Vec3(center.x + rr * cos(a), center.y + rr * sin(a), start.z + (end.z - start.z) * t))
        }
        out.append(end)
        return out
    }
}
