import CADCore
import Foundation

/// Builds dimension annotations from canvas clicks.
public enum DimensionBuilder {
    /// Clicks needed before a dimension of `kind` is made (radial kinds pick a curve instead).
    public static func clicksNeeded(_ kind: DimensionAnnotation.Kind) -> Int {
        switch kind {
        case .radius, .diameter: return 1
        default: return 3
        }
    }

    /// Linear: first point, second point, dimension line position. Angle: vertex, first arm,
    /// second arm (the arc sits at 60% of the shorter arm).
    public static func make(_ kind: DimensionAnnotation.Kind, clicks: [Vec2]) -> DimensionAnnotation? {
        guard clicks.count >= 3 else { return nil }
        switch kind {
        case .aligned, .horizontal, .vertical:
            guard clicks[0].distance(to: clicks[1]) > 1e-12 else { return nil }
            var d = DimensionAnnotation(kind: kind, points: [clicks[0], clicks[1]])
            d.offset = d.offset(through: clicks[2])
            return d
        case .angle:
            let r = min(clicks[1].distance(to: clicks[0]), clicks[2].distance(to: clicks[0]))
            guard r > 1e-12 else { return nil }
            return DimensionAnnotation(kind: .angle, points: Array(clicks.prefix(3)), offset: r * 0.6)
        case .radius, .diameter:
            return nil
        }
    }

    /// Radial dimension of an arc/circle with `center` and `radius`, pointing towards `toward`.
    public static func radial(_ kind: DimensionAnnotation.Kind, center: Vec2, radius: Double, toward: Vec2) -> DimensionAnnotation? {
        guard radius > 0 else { return nil }
        var dir = (toward - center).normalized
        if dir == .zero { dir = Vec2(1, 0) }
        return DimensionAnnotation(kind: kind == .diameter ? .diameter : .radius, points: [center, center + dir * radius])
    }

    /// Label text, e.g. "2.5 in", "R 0.75", "Ø 1.5", "45°".
    public static func label(_ d: DimensionAnnotation, units: LengthUnit) -> String {
        func f(_ v: Double) -> String { RulerTicks.label((v * 1000).rounded() / 1000) }
        switch d.kind {
        case .radius: return "R " + f(d.value)
        case .diameter: return "Ø " + f(d.value)
        case .angle: return f(d.value) + "°"
        default: return f(d.value) + " " + units.abbreviation
        }
    }
}
