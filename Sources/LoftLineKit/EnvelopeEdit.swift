import CADCore
import CAMCore
import Foundation

/// Interactive envelope distortion: the canvas shows the selection's bounding box as a quad
/// whose four corners can be dragged; Apply bends the vectors to follow (`VectorCommands.envelope`).
public struct EnvelopeEdit: Equatable {
    public var shapeIDs: [UUID]
    /// Bounding box of the shapes when the edit started.
    public var box: Rect2
    /// Corner offsets: lower-left, lower-right, upper-right, upper-left.
    public var offsets = [Vec2](repeating: .zero, count: 4)

    public static let cornerNames = ["Lower left", "Lower right", "Upper right", "Upper left"]

    /// Starts an edit on the editable part of `ids` (nil when there is nothing with an area).
    public init?(_ ids: [UUID], in project: LoftLineProject, offsets: [Vec2]? = nil) {
        let shapes = VectorCommands.editableShapes(project.document.expandToGroups(ids), in: project)
        let box = project.bounds(of: Set(shapes.map(\.id)))
        guard !shapes.isEmpty, !box.isEmpty, box.width > 0, box.height > 0 else { return nil }
        shapeIDs = shapes.map(\.id)
        self.box = box
        if let o = offsets, o.count == 4 { self.offsets = o }
    }

    public var corners: [Vec2] { [box.min, Vec2(box.max.x, box.min.y), box.max, Vec2(box.min.x, box.max.y)] }
    public var quad: [Vec2] { zip(corners, offsets).map { $0 + $1 } }
    public var isIdentity: Bool { offsets.allSatisfy { $0 == .zero } }

    /// Index of the quad corner within `tolerance` of `p` (nearest first).
    public func corner(at p: Vec2, tolerance: Double) -> Int? {
        quad.indices.filter { quad[$0].distance(to: p) <= tolerance }.min { quad[$0].distance(to: p) < quad[$1].distance(to: p) }
    }

    /// Drags corner `i` to `p`.
    public mutating func move(_ i: Int, to p: Vec2) {
        guard offsets.indices.contains(i) else { return }
        offsets[i] = p - corners[i]
    }

    /// Where a document point ends up under the current quad.
    public func map(_ p: Vec2) -> Vec2 { Distort.envelopeMap(p, box: box, quad: quad) }
}
