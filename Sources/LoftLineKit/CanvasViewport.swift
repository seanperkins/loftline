import CADCore
import Foundation

/// Maps document coordinates (material frame, Y up) to view points (Y up, unflipped NSView).
/// view = doc * scale + offset.
public struct CanvasViewport: Equatable {
    /// View points per document unit.
    public var scale: Double = 20
    /// View position of the document origin.
    public var offset: Vec2 = Vec2(40, 40)

    public static let minScale = 0.05
    public static let maxScale = 20_000.0

    public func toView(_ p: Vec2) -> Vec2 { p * scale + offset }
    public func toDocument(_ v: Vec2) -> Vec2 { (v - offset) / scale }

    /// Document-space length of `points` view points (for hit tolerances, handle sizes).
    public func documentLength(_ points: Double) -> Double { points / scale }

    public mutating func pan(by delta: Vec2) { offset += delta }

    /// Zooms by `factor`, keeping the document point under `anchor` (view) fixed.
    public mutating func zoom(by factor: Double, about anchor: Vec2) {
        let doc = toDocument(anchor)
        scale = min(max(scale * factor, Self.minScale), Self.maxScale)
        offset = anchor - doc * scale
    }

    /// Fits `rect` (document units) into a view of `size`, leaving `margin` points around it.
    public mutating func fit(_ rect: Rect2, viewSize size: Vec2, margin: Double = 40) {
        guard !rect.isEmpty, size.x > 2 * margin, size.y > 2 * margin else { return }
        let w = max(rect.width, 1e-6), h = max(rect.height, 1e-6)
        scale = min(max(min((size.x - 2 * margin) / w, (size.y - 2 * margin) / h), Self.minScale), Self.maxScale)
        offset = size * 0.5 - rect.center * scale
    }

    /// Visible document rectangle for a view of `size`.
    public func visibleRect(viewSize size: Vec2) -> Rect2 {
        Rect2(min: toDocument(.zero), max: toDocument(size))
    }

    public init(scale: Double = 20, offset: Vec2 = Vec2(40, 40)) {
        self.scale = scale
        self.offset = offset
    }
}

/// Ruler/grid tick spacing chosen so major ticks are at least `minSpacing` points apart.
public enum RulerTicks {
    /// Candidate major steps: 1-2-5 decades for mm; binary fractions then 1-2-6-12 for inches.
    public static func candidates(for units: LengthUnit) -> [Double] {
        switch units {
        case .inch:
            return [1.0 / 64, 1.0 / 32, 1.0 / 16, 0.125, 0.25, 0.5, 1, 2, 6, 12, 24, 48, 96, 240]
        case .millimeter:
            return [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000]
        }
    }

    /// Smallest candidate step whose on-screen spacing is ≥ `minSpacing` points.
    public static func majorStep(scale: Double, units: LengthUnit, minSpacing: Double = 60) -> Double {
        let c = candidates(for: units)
        return c.first { $0 * scale >= minSpacing } ?? c.last!
    }

    /// Minor subdivisions per major step (unit-system friendly).
    public static func subdivisions(of step: Double, units: LengthUnit) -> Int {
        switch units {
        case .inch: return step >= 6 ? (step.truncatingRemainder(dividingBy: 6) == 0 ? 6 : 4) : 4
        case .millimeter:
            let lead = step / pow(10, floor(log10(step)))
            return lead.rounded() == 2 ? 4 : (lead.rounded() == 5 ? 5 : 10)
        }
    }

    /// Multiples of `step` within [lo, hi].
    public static func values(from lo: Double, to hi: Double, step: Double) -> [Double] {
        guard step > 0, hi >= lo else { return [] }
        let first = (lo / step).rounded(.up)
        let last = (hi / step).rounded(.down)
        guard last >= first, last - first < 10_000 else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * step }
    }

    /// Ruler label: trims trailing zeros ("1.5", "12", "0.125").
    public static func label(_ v: Double) -> String {
        let s = String(format: "%.4f", v)
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }
}
