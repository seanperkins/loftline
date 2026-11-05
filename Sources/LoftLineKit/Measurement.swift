import CADCore
import Foundation

/// Result of the Measure tool: between two points, or of a clicked vector.
public struct Measurement: Equatable {
    public var from: Vec2?
    public var to: Vec2?
    /// Two-point readings.
    public var distance: Double?
    public var dx: Double?
    public var dy: Double?
    /// Angle of from→to in degrees (counter-clockwise from +X).
    public var angle: Double?
    /// Clicked vector readings.
    public var radius: Double?
    public var center: Vec2?
    public var length: Double?
    public var bounds: Rect2?
    public var name: String?

    public static func between(_ a: Vec2, _ b: Vec2) -> Measurement {
        let d = b - a
        var ang = atan2(d.y, d.x) * 180 / .pi
        if ang < 0 { ang += 360 }
        return Measurement(from: a, to: b, distance: d.length, dx: d.x, dy: d.y, angle: ang)
    }

    /// Readings of the path of `shape` nearest `p`: the radius when the nearest segment is an
    /// arc (or the shape is a parametric circle), the path length and the shape's bounds.
    public static func vector(_ shape: Shape, at p: Vec2, tolerance: Double) -> Measurement {
        var best: (path: Int, seg: Int, d: Double)?
        for (i, path) in shape.paths.enumerated() {
            let segs = PathSplitting.closedSegments(path)
            var cur = path.start
            for (j, s) in segs.enumerated() {
                let one = Path(start: cur, segments: [s])
                let d = PathSplitting.nearestParameter(PathSplitting.sample(one, tolerance: tolerance), to: p).distance
                if d < (best?.d ?? .infinity) { best = (i, j, d) }
                cur = s.end
            }
        }
        var m = Measurement(bounds: shape.bounds(), name: shape.name.isEmpty ? nil : shape.name)
        guard let b = best else { return m }
        let path = shape.paths[b.path]
        m.length = path.length(tolerance: tolerance / 20)
        let segs = PathSplitting.closedSegments(path)
        if case .arc(_, let c, _) = segs[b.seg] {
            let from = b.seg == 0 ? path.start : segs[b.seg - 1].end
            m.radius = from.distance(to: c)
            m.center = c
        } else if case .circle(let r) = shape.origin {
            m.radius = r
            m.center = shape.bounds().center
        }
        return m
    }

    /// Lines of text for display.
    public func lines(units: LengthUnit) -> [String] {
        let u = units.abbreviation
        func f(_ v: Double) -> String { RulerTicks.label((v * 10000).rounded() / 10000) }
        var out: [String] = []
        if let name { out.append(name) }
        if let distance { out.append("Distance \(f(distance)) \(u)") }
        if let dx, let dy { out.append("ΔX \(f(dx))  ΔY \(f(dy)) \(u)") }
        if let angle { out.append("Angle \(f(angle))°") }
        if let radius { out.append("Radius \(f(radius))  Ø \(f(radius * 2)) \(u)") }
        if let length { out.append("Length \(f(length)) \(u)") }
        if let b = bounds, !b.isEmpty { out.append("W \(f(b.width)) × H \(f(b.height)) \(u)") }
        return out
    }
}
