import Foundation

/// Curve flattening helpers shared by `Path` and CAM code.
public enum Flattening {
    /// Append points approximating `segment` (excluding its start point) to `pts`.
    public static func append(segment: PathSegment, from start: Vec2, tolerance: Double, to pts: inout [Vec2]) {
        let tol = max(tolerance, 1e-9)
        switch segment {
        case .line(let to):
            pts.append(to)
        case .arc(let to, let center, let cw):
            let r = start.distance(to: center)
            let sweep = arcSweep(from: start, to: to, center: center, clockwise: cw)
            // chord deviation r(1-cos(θ/2)) <= tol
            let maxStep = r > tol ? 2 * acos(max(-1, 1 - tol / r)) : Double.pi / 2
            let steps = ceil(abs(sweep) / max(maxStep, 1e-6))
            guard steps.isFinite, r.isFinite else { pts.append(to); return }   // corrupt arc: a line
            let n = max(1, Int(steps))
            let a0 = (start - center).angle
            for i in 1..<n {
                let a = a0 + sweep * Double(i) / Double(n)
                pts.append(center + Vec2(cos(a), sin(a)) * r)
            }
            pts.append(to)
        case .cubic(let to, let c1, let c2):
            // Uniform subdivision count from the control polygon's second differences.
            let d = max((start - c1 * 2 + c2).length, (c1 - c2 * 2 + to).length)
            guard d.isFinite else { pts.append(to); return }   // corrupt control points: a line
            // Clamp as a Double first: a finite but astronomical `d` overflows `Int` before `min` can cap it (#121).
            let n = max(1, Int(min(1000, ceil(sqrt(0.75 * d / tol)))))
            for i in 1..<n {
                pts.append(cubicPoint(start, c1, c2, to, Double(i) / Double(n)))
            }
            pts.append(to)
        }
    }

    /// Signed sweep angle (radians): negative for clockwise. A full circle (start == end)
    /// returns ±2π.
    public static func arcSweep(from start: Vec2, to end: Vec2, center: Vec2, clockwise: Bool) -> Double {
        let a0 = (start - center).angle
        let a1 = (end - center).angle
        var sweep = a1 - a0
        if clockwise {
            while sweep >= 0 { sweep -= 2 * .pi }
            if sweep < -2 * .pi { sweep += 2 * .pi }
        } else {
            while sweep <= 0 { sweep += 2 * .pi }
            if sweep > 2 * .pi { sweep -= 2 * .pi }
        }
        return sweep
    }

    public static func cubicPoint(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ t: Double) -> Vec2 {
        let mt = 1 - t
        return p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t)
    }

    /// Convert an arc into ≤90° cubic Bézier segments.
    public static func arcToCubics(from start: Vec2, to end: Vec2, center: Vec2, clockwise: Bool) -> [PathSegment] {
        let r = start.distance(to: center)
        let sweep = arcSweep(from: start, to: end, center: center, clockwise: clockwise)
        guard sweep.isFinite, r.isFinite else { return [.line(to: end)] }
        let n = max(1, Int(ceil(abs(sweep) / (.pi / 2) - 1e-9)))
        let step = sweep / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [PathSegment] = []
        var a = (start - center).angle
        var p = start
        for i in 0..<n {
            let a2 = a + step
            let e = i == n - 1 ? end : center + Vec2(cos(a2), sin(a2)) * r
            let c1 = p + Vec2(-sin(a), cos(a)) * (r * k)
            let c2 = e - Vec2(-sin(a2), cos(a2)) * (r * k)
            out.append(.cubic(to: e, control1: c1, control2: c2))
            a = a2; p = e
        }
        return out
    }
}
