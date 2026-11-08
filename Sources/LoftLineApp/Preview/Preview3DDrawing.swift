// Drawing polylines and picking vectors in the 3D preview. Owned by preview.
import CADCore
import Foundation
import LoftLineKit

/// What a plain click on the 3D view does.
enum Preview3DTool: String, CaseIterable, Identifiable {
    /// Clicks only orbit the camera (default).
    case none
    /// Click a vector to select it (the 2D canvas follows); click empty stock to clear.
    case select
    /// Click points on the stock or the material-top plane to draw a polyline.
    case draw
    /// Click the stock for a depth, twice for a distance.
    case measure

    var id: Self { self }
}

/// A click in the 3D view, resolved to the material frame.
struct Preview3DPick: Equatable {
    /// Material-frame point (z = -depth); on the material-top plane when `onStock` is false.
    var point: Vec3
    /// About 8 screen pixels at the clicked point, in document units (for snapping and picking).
    var tolerance: Double
    /// True when the click hit the simulated stock mesh.
    var onStock: Bool
}

/// A polyline being drawn in the 3D view, in the material (document) frame on the material top.
/// Clicks add points; clicking the first point again closes the shape, clicking the last point
/// again finishes it open. Points snap to nearby vector nodes.
struct Preview3DDrawing: Equatable {
    private(set) var points: [Vec2] = []

    enum ClickResult: Equatable {
        case added
        /// The shape is complete; `closed` when it returned to its first point.
        case finished(points: [Vec2], closed: Bool)
    }

    var isEmpty: Bool { points.isEmpty }

    /// `p` moved onto the nearest snap target within `tolerance`, else unchanged.
    static func snapped(_ p: Vec2, tolerance: Double, targets: [Vec2]) -> Vec2 {
        var best: (q: Vec2, d: Double)?
        for q in targets {
            let d = q.distance(to: p)
            if d <= tolerance, d < (best?.d ?? .infinity) { best = (q, d) }
        }
        return best?.q ?? p
    }

    /// Adds a click. The drawing resets itself when a shape is finished.
    mutating func click(_ raw: Vec2, tolerance: Double, snapTargets: [Vec2] = []) -> ClickResult {
        let p = Self.snapped(raw, tolerance: tolerance, targets: snapTargets)
        if points.count >= 3, p.distance(to: points[0]) <= tolerance {
            let done = points
            points = []
            return .finished(points: done, closed: true)
        }
        if points.count >= 2, let last = points.last, p.distance(to: last) <= tolerance {
            let done = points
            points = []
            return .finished(points: done, closed: false)
        }
        if let last = points.last, p.distance(to: last) <= tolerance { return .added } // stray double-click
        points.append(p)
        return .added
    }

    /// Finishes the drawing open (Return / Finish). Nil when there are fewer than two points.
    mutating func finish() -> [Vec2]? {
        defer { points = [] }
        return points.count >= 2 ? points : nil
    }

    mutating func undoLastPoint() { if !points.isEmpty { points.removeLast() } }
    mutating func cancel() { points = [] }

    /// The finished points as a document shape (polyline or closed polygon) on `layerID`.
    static func shape(points: [Vec2], closed: Bool, layerID: UUID) -> Shape? {
        guard points.count >= 2 else { return nil }
        var pts = points
        if closed, let first = pts.first { pts.append(first) }
        // A closed result only needs the close point to coincide with the first.
        return DrawingTools.polyline(points: pts, closeTolerance: closed ? 1e-9 : 0, layerID: layerID)
    }
}

extension Preview3DDrawing {
    /// The vector under a 3D-view click, picked the way the 2D canvas picks (nearest outline
    /// within `tolerance`, else the smallest closed shape around the point).
    static func pickShape(at p: Vec2, in shapes: [Shape], tolerance: Double) -> UUID? {
        let flat = shapes.map { FlatShape($0, tolerance: max(tolerance / 4, 1e-4)) }
        return HitTesting.pick(at: p, in: flat, tolerance: tolerance)
    }
}
