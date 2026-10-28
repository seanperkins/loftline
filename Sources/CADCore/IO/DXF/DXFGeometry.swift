import Foundation

/// Converts DXF entities to `Path`s in DXF drawing units (WCS, Y up).
enum DXFGeometry {
    /// Paths for one entity, or nil if the entity type is not geometric / unsupported.
    static func paths(for e: DXFEntity, splineTolerance: Double) -> [Path]? {
        let ocs: Transform2D = e.isMirroredOCS ? .scale(-1, 1) : .identity
        func p(_ cx: Int, _ cy: Int) -> Vec2 { Vec2(e.double(cx) ?? 0, e.double(cy) ?? 0) }
        switch e.type {
        case "LINE":
            let a = p(10, 20), b = p(11, 21)
            return a == b ? [] : [Path(points: [a, b], closed: false)]
        case "CIRCLE":
            guard let r = e.double(40), r > 0 else { return [] }
            return [ShapeFactory.circle(center: p(10, 20), radius: r).transformed(ocs)]
        case "ARC":
            guard let r = e.double(40), r > 0 else { return [] }
            return [arc(center: p(10, 20), radius: r, startDeg: e.double(50) ?? 0, endDeg: e.double(51) ?? 360).transformed(ocs)]
        case "ELLIPSE":
            return [ellipse(e)]
        case "LWPOLYLINE":
            let xs = e.doubles(10), ys = e.doubles(20)
            // Bulges (42) belong to the most recent vertex.
            var bulges = [Double](repeating: 0, count: xs.count)
            var vi = -1
            for (code, value) in e.pairs {
                if code == 10 { vi += 1 } else if code == 42, vi >= 0, vi < bulges.count { bulges[vi] = Double(value) ?? 0 }
            }
            let pts = zip(xs, ys).map { Vec2($0, $1) }
            let closed = ((e.int(70) ?? 0) & 1) != 0
            return polyline(pts, bulges: bulges, closed: closed).map { [$0.transformed(ocs)] } ?? []
        case "POLYLINE":
            let flags = e.int(70) ?? 0
            if flags & (16 | 64) != 0 { return nil } // polygon / polyface meshes
            let verts = e.vertices.filter { (($0.int(70) ?? 0) & 16) == 0 } // skip spline frame points
            let pts = verts.map { Vec2($0.double(10) ?? 0, $0.double(20) ?? 0) }
            let bulges = verts.map { $0.double(42) ?? 0 }
            return polyline(pts, bulges: bulges, closed: flags & 1 != 0).map { [$0.transformed(ocs)] } ?? []
        case "SPLINE":
            return spline(e, tolerance: splineTolerance).map { [$0] } ?? []
        case "POINT":
            return []
        default:
            return nil
        }
    }

    /// CCW arc from `startDeg` to `endDeg`; equal angles mean a full circle.
    static func arc(center c: Vec2, radius r: Double, startDeg: Double, endDeg: Double) -> Path {
        let a0 = startDeg * .pi / 180
        var sweep = (endDeg - startDeg).truncatingRemainder(dividingBy: 360)
        if sweep <= 1e-9 { sweep += 360 }
        let start = c + Vec2(cos(a0), sin(a0)) * r
        if sweep >= 360 - 1e-9 { return ShapeFactory.circle(center: c, radius: r).rotatedStart(to: start, center: c) }
        let a1 = a0 + sweep * .pi / 180
        return Path(start: start, segments: [.arc(to: c + Vec2(cos(a1), sin(a1)) * r, center: c, clockwise: false)])
    }

    /// Polyline with DXF bulges (bulge i = tan(θ/4) for the segment from vertex i to i+1;
    /// positive = counter-clockwise).
    static func polyline(_ ptsIn: [Vec2], bulges: [Double], closed: Bool) -> Path? {
        var pts = ptsIn, b = bulges
        // Drop a duplicated closing vertex.
        if closed, pts.count > 2, pts.last == pts.first { pts.removeLast(); b.removeLast() }
        guard pts.count > 1 else { return nil }
        var path = Path(start: pts[0], isClosed: closed)
        let n = closed ? pts.count : pts.count - 1
        for i in 0..<n {
            let p1 = pts[i], p2 = pts[(i + 1) % pts.count]
            let bulge = i < b.count ? b[i] : 0
            if p1 == p2 { continue }
            if abs(bulge) < 1e-12 {
                if !(closed && i == n - 1) { path.segments.append(.line(to: p2)) }
            } else {
                path.segments.append(contentsOf: bulgeArc(from: p1, to: p2, bulge: bulge))
            }
        }
        return path.segments.isEmpty ? nil : path
    }

    static func bulgeArc(from p1: Vec2, to p2: Vec2, bulge: Double) -> [PathSegment] {
        let chord = p2 - p1
        let d = chord.length
        let n = chord.normalized.perpendicular
        let center = (p1 + p2) * 0.5 + n * (d / 4 * (1 / bulge - bulge))
        let cw = bulge < 0
        // Split > 180° arcs so the sweep is unambiguous.
        if abs(bulge) > 1 + 1e-12 {
            let r = p1.distance(to: center)
            let sweep = 4 * atan(bulge)
            let a = (p1 - center).angle + sweep / 2
            let mid = center + Vec2(cos(a), sin(a)) * r
            return [.arc(to: mid, center: center, clockwise: cw), .arc(to: p2, center: center, clockwise: cw)]
        }
        return [.arc(to: p2, center: center, clockwise: cw)]
    }

    static func ellipse(_ e: DXFEntity) -> Path {
        let c = Vec2(e.double(10) ?? 0, e.double(20) ?? 0)
        let major = Vec2(e.double(11) ?? 1, e.double(21) ?? 0)
        let ratio = e.double(40) ?? 1
        // Minor axis = extrusion × major: flips when the extrusion points down.
        let minor = major.perpendicular * (e.isMirroredOCS ? -ratio : ratio)
        let t0 = e.double(41) ?? 0, t1 = e.double(42) ?? 2 * .pi
        // A remainder, not a loop: at 1e20 adding 2π changes nothing and the loop never ended (#121).
        var sweep = (t1 - t0).truncatingRemainder(dividingBy: 2 * .pi)
        if !sweep.isFinite { sweep = 2 * .pi }
        if sweep <= 1e-9 { sweep += 2 * .pi }
        let full = sweep >= 2 * .pi - 1e-9
        if full { sweep = 2 * .pi }
        func map(_ u: Vec2) -> Vec2 { c + major * u.x + minor * u.y }
        let n = max(1, Int(ceil(sweep / (.pi / 2) - 1e-9)))
        let step = sweep / Double(n), k = 4.0 / 3.0 * tan(step / 4)
        var path = Path(start: map(Vec2(cos(t0), sin(t0))), isClosed: full)
        var a = t0
        for _ in 0..<n {
            let b = a + step
            let s0 = Vec2(cos(a), sin(a)), s1 = Vec2(cos(b), sin(b))
            path.segments.append(.cubic(to: map(s1), control1: map(s0 + s0.perpendicular * k),
                                        control2: map(s1 - s1.perpendicular * k)))
            a = b
        }
        if full, let last = path.segments.indices.last, case .cubic(_, let c1, let c2) = path.segments[last] {
            path.segments[last] = .cubic(to: path.start, control1: c1, control2: c2)
        }
        return path
    }

    /// NURBS evaluated by de Boor and sampled (control points), or a Catmull-Rom curve through
    /// fit points when no control points are given.
    static func spline(_ e: DXFEntity, tolerance: Double) -> Path? {
        let flags = e.int(70) ?? 0
        let closed = flags & 1 != 0
        let ctrl = zip(e.doubles(10), e.doubles(20)).map { Vec2($0, $1) }
        let fit = zip(e.doubles(11), e.doubles(21)).map { Vec2($0, $1) }
        if ctrl.count >= 2 {
            // A degree-p NURBS needs at least p + 1 control points; sloppy exporters write a short
            // polyline as a degree-3 SPLINE, which would index outside the knot vector.
            let degree = min(max(1, e.int(71) ?? 3), ctrl.count - 1)
            var knots = e.doubles(40)
            var weights = e.doubles(41)
            if weights.count != ctrl.count { weights = [Double](repeating: 1, count: ctrl.count) }
            if knots.count != ctrl.count + degree + 1 {
                knots = clampedUniformKnots(count: ctrl.count, degree: degree)
            }
            let pts = sampleNURBS(ctrl: ctrl, weights: weights, knots: knots, degree: degree, tolerance: tolerance)
            var path = Path(points: pts, closed: closed)
            if closed, pts.count > 2, pts.last!.isApproximatelyEqual(to: pts[0], tolerance: 1e-9) {
                path = Path(points: Array(pts.dropLast()), closed: true)
            }
            return path
        }
        if fit.count >= 2 { return catmullRom(fit, closed: closed) }
        return nil
    }

    static func clampedUniformKnots(count n: Int, degree p: Int) -> [Double] {
        let inner = max(0, n - p - 1)
        return [Double](repeating: 0, count: p + 1) + (0..<inner).map { Double($0 + 1) / Double(inner + 1) }
            + [Double](repeating: 1, count: p + 1)
    }

    static func sampleNURBS(ctrl: [Vec2], weights: [Double], knots: [Double], degree p: Int, tolerance: Double) -> [Vec2] {
        let n = ctrl.count
        let hi = knots[n]
        // Samples per span from control-polygon size relative to tolerance.
        let poly = zip(ctrl, ctrl.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        let spans = max(1, Set(knots[p...n]).count - 1)
        let per = max(8, min(200, Int((poly / Double(spans) / max(tolerance, 1e-6)).squareRoot())))
        var out: [Vec2] = []
        for s in p..<n where knots[s + 1] > knots[s] {
            let a = knots[s], b = knots[s + 1]
            for i in 0..<per {
                out.append(deBoor(ctrl, weights, knots, p, span: s, t: a + (b - a) * Double(i) / Double(per)))
            }
        }
        out.append(deBoor(ctrl, weights, knots, p, span: lastSpan(knots, p, n), t: hi))
        return out
    }

    private static func lastSpan(_ knots: [Double], _ p: Int, _ n: Int) -> Int {
        var s = n - 1
        while s > p, knots[s + 1] <= knots[s] { s -= 1 }
        return s
    }

    /// Rational de Boor evaluation in homogeneous coordinates.
    static func deBoor(_ ctrl: [Vec2], _ w: [Double], _ knots: [Double], _ p: Int, span k: Int, t: Double) -> Vec2 {
        var d: [(x: Double, y: Double, w: Double)] = (0...p).map { j in
            let i = j + k - p
            return (ctrl[i].x * w[i], ctrl[i].y * w[i], w[i])
        }
        if p >= 1 {
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = j + k - p
                    let den = knots[i + 1 + p - r] - knots[i]
                    let alpha = den == 0 ? 0 : (t - knots[i]) / den
                    d[j] = ((1 - alpha) * d[j - 1].x + alpha * d[j].x,
                            (1 - alpha) * d[j - 1].y + alpha * d[j].y,
                            (1 - alpha) * d[j - 1].w + alpha * d[j].w)
                }
            }
        }
        let r = d[p]
        return r.w == 0 ? Vec2(r.x, r.y) : Vec2(r.x / r.w, r.y / r.w)
    }

    /// Centripetal-free (uniform) Catmull-Rom through points, as cubic Béziers.
    static func catmullRom(_ pts: [Vec2], closed: Bool) -> Path {
        let n = pts.count
        func at(_ i: Int) -> Vec2 {
            if closed { return pts[((i % n) + n) % n] }
            return pts[min(max(i, 0), n - 1)]
        }
        var path = Path(start: pts[0], isClosed: closed)
        for i in 0..<(closed ? n : n - 1) {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            path.segments.append(.cubic(to: p2, control1: p1 + (p2 - p0) / 6, control2: p2 - (p3 - p1) / 6))
        }
        return path
    }
}

extension Path {
    /// Same closed circle as `self` (from `ShapeFactory.circle`) but starting at `p`.
    func rotatedStart(to p: Vec2, center c: Vec2) -> Path {
        let opposite = c * 2 - p
        return Path(start: p, segments: [.arc(to: opposite, center: c, clockwise: false),
                                         .arc(to: p, center: c, clockwise: false)], isClosed: true)
    }
}
