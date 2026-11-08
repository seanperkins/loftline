import Foundation

/// Marks a layer as clamp / fixture zones: its closed vectors are areas the cutter must not
/// enter. `height` is how far the clamp stands above the material top (0 = flush, e.g. screw
/// heads or tape), so rapids must also stay clear when the clamp is taller than safe Z.
public struct LayerKeepOut: Codable, Hashable, Sendable {
    public var height: Double

    public init(height: Double = 0) { self.height = height }
}

/// Clamp zones and fixture-hole patterns. Lengths in document units, material frame.
public enum Fixtures {
    /// One keep-out area: flattened closed loops (even-odd) and the clamp height.
    public struct Zone: Hashable, Sendable {
        public var name: String
        public var loops: [[Vec2]]
        public var height: Double
        /// The keep-out layer the shape is on.
        public var layerID: UUID?

        public init(name: String, loops: [[Vec2]], height: Double, layerID: UUID? = nil) {
            self.name = name; self.loops = loops; self.height = height; self.layerID = layerID
        }
    }

    public static func keepOutLayerIDs(in doc: Document) -> Set<UUID> {
        Set(doc.layers.filter { $0.keepOut != nil }.map(\.id))
    }

    /// Closed shapes on keep-out layers (hidden layers included: a clamp is there either way).
    public static func zones(in doc: Document, tolerance: Double = Path.defaultTolerance) -> [Zone] {
        var out: [Zone] = []
        for layer in doc.layers {
            guard let k = layer.keepOut else { continue }
            for s in doc.shapes where s.layerID == layer.id {
                let loops = s.paths.filter(\.isClosed).map { $0.flattened(tolerance: tolerance) }.filter { $0.count > 2 }
                guard !loops.isEmpty else { continue }
                out.append(Zone(name: s.name.isEmpty ? layer.name : s.name, loops: loops, height: max(0, k.height), layerID: layer.id))
            }
        }
        return out
    }

    /// Clamp footprints along the material edges. Each clamp is `length` along the edge and
    /// reaches `reach` onto the material, plus `outside` beyond the edge. `perSideEdges` clamps go
    /// on the left and right edges, `perEndEdges` on the bottom and top, spread evenly with the
    /// end clamps `endInset` from the corners.
    public static func clampRects(job: JobSetup, length: Double, reach: Double, outside: Double,
                                  perSideEdges: Int, perEndEdges: Int, endInset: Double) -> [Rect2] {
        func centres(span: Double, count: Int) -> [Double] {
            guard count > 0 else { return [] }
            let lo = min(span / 2, endInset + length / 2), hi = max(span / 2, span - endInset - length / 2)
            if count == 1 { return [span / 2] }
            return (0..<count).map { lo + (hi - lo) * Double($0) / Double(count - 1) }
        }
        var rects: [Rect2] = []
        for c in centres(span: job.height, count: perSideEdges) {
            rects.append(Rect2(min: Vec2(-outside, c - length / 2), max: Vec2(reach, c + length / 2)))
            rects.append(Rect2(min: Vec2(job.width - reach, c - length / 2), max: Vec2(job.width + outside, c + length / 2)))
        }
        for c in centres(span: job.width, count: perEndEdges) {
            rects.append(Rect2(min: Vec2(c - length / 2, -outside), max: Vec2(c + length / 2, reach)))
            rects.append(Rect2(min: Vec2(c - length / 2, job.height - reach), max: Vec2(c + length / 2, job.height + outside)))
        }
        return rects
    }

    /// Hole centres on a grid inside `area` inset by `inset`, `spacing` apart, centred so the
    /// leftover is split evenly on both sides.
    public static func holeGrid(in area: Rect2, spacing: Vec2, inset: Double) -> [Vec2] {
        let a = area.insetBy(inset)
        guard !a.isEmpty, spacing.x > 0, spacing.y > 0 else { return [] }
        let nx = Int((a.width / spacing.x + 1e-9).rounded(.down)) + 1
        let ny = Int((a.height / spacing.y + 1e-9).rounded(.down)) + 1
        let x0 = a.min.x + (a.width - Double(nx - 1) * spacing.x) / 2
        let y0 = a.min.y + (a.height - Double(ny - 1) * spacing.y) / 2
        var pts: [Vec2] = []
        for j in 0..<ny { for i in 0..<nx { pts.append(Vec2(x0 + Double(i) * spacing.x, y0 + Double(j) * spacing.y)) } }
        return pts
    }
}
