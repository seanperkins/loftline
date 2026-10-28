import Foundation

/// One point of a form tool's outline: the cutting radius at `height` above the tip
/// (toolpaths-2d addition). Lengths in the tool's units.
public struct FormToolPoint: Codable, Hashable, Sendable {
    public var height: Double
    public var radius: Double

    public init(height: Double, radius: Double) { self.height = height; self.radius = radius }
}

/// A cutter outline other than the plain one implied by `ToolKind` (toolpaths-2d addition).
/// Lengths are in the tool's units; angles in degrees.
public enum CutterShape: Codable, Hashable, Sendable {
    /// End mill with radiused corners ("bull nose"): flat bottom out to radius − cornerRadius.
    case bullNose(cornerRadius: Double)
    /// Ball tip of `tipRadius` blending into a cone that widens at `halfAngle` from the axis
    /// up to the tool's diameter.
    case taperedBallNose(tipRadius: Double, halfAngle: Double)
    /// Any turned outline (roundover, ogee, cove…): cutting radius against height above the tip,
    /// from the tip upward. Straight lines join the points.
    case form(points: [FormToolPoint])

    public var displayName: String {
        switch self {
        case .bullNose: return "Bull Nose"
        case .taperedBallNose: return "Tapered Ball Nose"
        case .form: return "Form Tool"
        }
    }

    /// The same outline within `tolerance` (lengths, in the units both are given in; angles to 1e-6): a shape scaled between
    /// units, or rounded, is still the same cutter.
    static func same(_ a: CutterShape?, _ b: CutterShape?, tolerance: Double) -> Bool {
        func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) < tolerance }
        switch (a, b) {
        case (nil, nil): return true
        case (.bullNose(let c0)?, .bullNose(let c1)?): return close(c0, c1)
        case (.taperedBallNose(let t0, let a0)?, .taperedBallNose(let t1, let a1)?): return close(t0, t1) && abs(a0 - a1) < 1e-6
        case (.form(let p0)?, .form(let p1)?):
            return p0.count == p1.count && zip(p0, p1).allSatisfy { close($0.height, $1.height) && close($0.radius, $1.radius) }
        default: return false
        }
    }

    func scaled(by f: Double) -> CutterShape {
        switch self {
        case .bullNose(let c): return .bullNose(cornerRadius: c * f)
        case .taperedBallNose(let t, let a): return .taperedBallNose(tipRadius: t * f, halfAngle: a)
        case .form(let pts): return .form(points: pts.map { FormToolPoint(height: $0.height * f, radius: $0.radius * f) })
        }
    }

    /// Form points cleaned for use: finite, non-negative, sorted by height, and starting at the
    /// tip (a point at height 0 is added with the first radius when missing).
    static func normalizedForm(_ pts: [FormToolPoint]) -> [FormToolPoint] {
        var p = pts.filter { $0.height.isFinite && $0.radius.isFinite }
            .map { FormToolPoint(height: max(0, $0.height), radius: max(0, $0.radius)) }
            .sorted { $0.height < $1.height }
        if let first = p.first, first.height > 0 { p.insert(FormToolPoint(height: 0, radius: first.radius), at: 0) }
        return p
    }

    /// Height of the lowest point of the cutter at radial distance `r` above the tip, for a tool
    /// of outer radius `R`; nil outside the tool. For form tools this is the lowest height whose
    /// outline radius reaches `r` (undercuts are seen from below, as a top-down heightfield can).
    public func heightAboveTip(atRadius r: Double, toolRadius R: Double) -> Double? {
        let r = abs(r)
        guard r <= R + 1e-12 else { return nil }
        switch self {
        case .bullNose(let c0):
            let c = min(max(c0, 0), R)
            let flat = R - c
            guard r > flat else { return 0 }
            let u = min(r - flat, c)
            return c - max(c * c - u * u, 0).squareRoot()
        case .taperedBallNose(let tip0, let half0):
            let tip = min(max(tip0, 0), R)
            let a = min(max(half0, 0.01), 89.99) * .pi / 180
            let rt = tip * cos(a) // where the cone touches the ball
            if r <= rt { return tip - max(tip * tip - r * r, 0).squareRoot() }
            return (tip - tip * sin(a)) + (r - rt) / tan(a)
        case .form(let raw):
            let pts = Self.normalizedForm(raw)
            guard let first = pts.first else { return 0 }
            if r <= first.radius { return 0 }
            for (a, b) in zip(pts, pts.dropFirst()) where b.radius >= r {
                // Segment a→b reaches r; a.radius < r here (else an earlier segment did).
                guard a.radius < r else { return a.height }
                let t = (r - a.radius) / (b.radius - a.radius)
                return a.height + t * (b.height - a.height)
            }
            // Wider than the outline (diameter larger than the form): the side above the top point.
            return pts.last?.height
        }
    }

    /// A problem that makes the shape unusable on a tool of outer radius `R`, or nil.
    public func problem(toolRadius R: Double) -> String? {
        switch self {
        case .bullNose(let c):
            if !(c > 0) { return "The corner radius must be above zero." }
            if c > R + 1e-9 { return "The corner radius is larger than the tool radius." }
        case .taperedBallNose(let tip, let half):
            if !(tip > 0) { return "The tip radius must be above zero." }
            if tip > R + 1e-9 { return "The tip radius is larger than the tool radius." }
            if !(half > 0 && half < 90) { return "The taper half-angle must be between 0° and 90°." }
        case .form(let pts):
            let p = Self.normalizedForm(pts)
            if p.count < 2 { return "A form tool needs at least two outline points." }
            if (p.map(\.radius).max() ?? 0) <= 0 { return "The form outline has no width." }
            if (p.map(\.radius).max() ?? 0) > R + 1e-9 { return "The form outline is wider than the tool diameter." }
        }
        return nil
    }
}

extension Tool {
    /// The tool's special shape when it applies to its kind (bull nose: end mills; tapered
    /// ball: ball noses; form: end mills and ball noses), else nil = the plain shape.
    public var effectiveShape: CutterShape? {
        guard let s = shape, s.problem(toolRadius: radius) == nil else { return nil }
        switch (s, kind) {
        case (.bullNose, .endMill), (.taperedBallNose, .ballNose), (.form, .endMill), (.form, .ballNose): return s
        default: return nil
        }
    }

    /// Height of the cutting surface above the tip at radial distance `r`, or nil outside the
    /// tool. The single source of truth for cutter geometry (simulation, drop-cutter, moulding).
    public func heightAboveTip(atRadius r: Double) -> Double? {
        let R = radius
        let r = abs(r)
        guard r <= R + 1e-12 else { return nil }
        if let s = effectiveShape { return s.heightAboveTip(atRadius: r, toolRadius: R) }
        switch kind {
        case .endMill: return 0
        case .ballNose: return R - max(R * R - r * r, 0).squareRoot()
        case .vBit, .engraving, .drill:
            guard let a = angle, a > 0, a < 180 else { return 0 }
            let tip = min(R, tipDiameter / 2)
            return r <= tip ? 0 : (r - tip) / tan(a / 2 * .pi / 180)
        }
    }

    /// Width of the groove the tool cuts when its tip is `depth` below the surface.
    public func cutWidth(atDepth depth: Double) -> Double {
        let d = max(depth, 0)
        guard let h = heightAboveTip(atRadius: radius), h > d else { return diameter }
        // h(r) is non-decreasing for every shape: bisect for the widest r with h(r) ≤ d.
        var lo = 0.0, hi = radius
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if (heightAboveTip(atRadius: mid) ?? .infinity) <= d { lo = mid } else { hi = mid }
        }
        return 2 * lo
    }

    /// Short description of a special shape for lists and headers ("bull nose r0.03"), or nil.
    public var shapeSummary: String? {
        guard let s = effectiveShape else { return nil }
        func n(_ x: Double) -> String { String(format: "%.4g", x) }
        switch s {
        case .bullNose(let c): return "bull nose r\(n(c))"
        case .taperedBallNose(let t, let a): return "tapered ball r\(n(t)) \(n(a))°/side"
        case .form(let p): return "form tool (\(p.count) points)"
        }
    }
}
