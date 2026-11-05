import CADCore
import CAMCore
import Foundation

/// Copy/paste/duplicate: fresh IDs, groups remapped so copies form their own groups, shapes on
/// missing layers moved to `fallbackLayer`.
public enum ShapeClipboard {
    public static func copies(of shapes: [Shape], offset: Vec2, layers: Set<UUID>, fallbackLayer: UUID) -> [Shape] {
        var groupMap: [UUID: UUID] = [:]
        return shapes.map { s in
            var c = offset == .zero ? s : s.transformed(.translation(offset))
            c.id = UUID()
            if !layers.contains(c.layerID) { c.layerID = fallbackLayer }
            func remap(_ g: UUID) -> UUID {
                if let n = groupMap[g] { return n }
                let n = UUID()
                groupMap[g] = n
                return n
            }
            c.groupID = s.groupID.map(remap)
            c.innerGroupIDs = s.innerGroupIDs?.map(remap)
            return c
        }
    }

    /// Pasted shapes are offset by one grid step when the originals still exist in the
    /// document (so the copy is visible), otherwise pasted in place.
    public static func pasteOffset(for shapes: [Shape], existing: Set<UUID>, grid: Double) -> Vec2 {
        shapes.contains { existing.contains($0.id) } ? Vec2(grid, -grid) : .zero
    }

    public static func encode(_ shapes: [Shape]) -> Data? { try? JSONEncoder().encode(shapes) }
    public static func decode(_ data: Data) -> [Shape]? { try? JSONDecoder().decode([Shape].self, from: data) }
}

extension LoftLineProject {
    /// Adds copies of `shapes` and returns their IDs.
    public mutating func paste(_ shapes: [Shape], offset: Vec2, fallbackLayer: UUID) -> [UUID] {
        let layers = Set(document.layers.map(\.id))
        let copies = ShapeClipboard.copies(of: shapes, offset: offset, layers: layers, fallbackLayer: fallbackLayer)
        copies.forEach { document.add($0) }
        return copies.map(\.id)
    }

    /// Moves a layer up (-1) or down (+1) in the list.
    public mutating func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = document.layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard document.layers.indices.contains(j) else { return }
        document.layers.swapAt(i, j)
    }

    // MARK: Node editing

    /// Applies a node edit to one editable shape; returns false if the shape is missing/locked.
    @discardableResult
    public mutating func editNodes(of id: UUID, _ f: (Shape) -> Shape?) -> Bool {
        guard let i = document.shapes.firstIndex(where: { $0.id == id }), isEditable(document.shapes[i]),
              var s = f(document.shapes[i]) else { return false }
        // Node edits turn live text into plain curves.
        if s.paths != document.shapes[i].paths { s.text = nil }
        document.shapes[i] = s
        return true
    }

    public mutating func moveNodes(_ refs: Set<NodeRef>, by delta: Vec2, mirror: NodeMirrorMode = .off) {
        for id in Set(refs.map(\.shapeID)) { editNodes(of: id) { NodeMirror.moveNodes($0, refs, by: delta, mode: mirror) } }
    }

    /// Deletes nodes; shapes whose paths would degenerate are left unchanged.
    public mutating func deleteNodes(_ refs: Set<NodeRef>) {
        for id in Set(refs.map(\.shapeID)) { editNodes(of: id) { ShapeNodes.deleteNodes($0, refs) } }
    }

    public mutating func setNodes(_ refs: Set<NodeRef>, smooth: Bool) {
        for id in Set(refs.map(\.shapeID)) { editNodes(of: id) { ShapeNodes.setNodes($0, refs, smooth: smooth) } }
    }

    /// Converts the segment leaving each node (the closing segment for the last node of a
    /// closed path) to a line or a curve.
    public mutating func convertSegments(after refs: Set<NodeRef>, toCurve: Bool) {
        for r in refs {
            editNodes(of: r.shapeID) { s in
                let e = ShapeNodes.editable(s)
                guard e.paths.indices.contains(r.path),
                      let seg = PathNodes.outgoingSegment(e.paths[r.path], r.node) else { return nil }
                return ShapeNodes.convertSegment(e, SegmentRef(shapeID: s.id, path: r.path, segment: seg), toCurve: toCurve)
            }
        }
    }

    /// Inserts a node midway along the segment after each node. Returns the new node refs.
    public mutating func insertNodesAfter(_ refs: Set<NodeRef>) -> Set<NodeRef> {
        var out = Set<NodeRef>()
        // Highest index first so earlier insertions do not shift later ones.
        for r in refs.sorted(by: { ($0.path, $0.node) > ($1.path, $1.node) }) {
            editNodes(of: r.shapeID) { s in
                let e = ShapeNodes.editable(s)
                guard e.paths.indices.contains(r.path),
                      let seg = PathNodes.outgoingSegment(e.paths[r.path], r.node) else { return nil }
                out.insert(NodeRef(shapeID: s.id, path: r.path, node: seg + 1))
                return ShapeNodes.insertNode(e, SegmentRef(shapeID: s.id, path: r.path, segment: seg), t: 0.5)
            }
        }
        return out
    }

    /// Valid node refs only (shape exists, indices in range).
    public func validNodes(_ refs: Set<NodeRef>) -> Set<NodeRef> {
        refs.filter { r in
            guard let s = document.shape(id: r.shapeID), s.paths.indices.contains(r.path) else { return false }
            return r.node < PathNodes.anchorCount(PathNodes.editable(s.paths[r.path]))
        }
    }

    /// Position of a node (editable form).
    public func nodePosition(_ r: NodeRef) -> Vec2? {
        guard let s = document.shape(id: r.shapeID), s.paths.indices.contains(r.path) else { return nil }
        let p = PathNodes.editable(s.paths[r.path])
        return r.node < PathNodes.anchorCount(p) ? PathNodes.anchor(p, r.node) : nil
    }
}

extension DesignCommands {
    /// Groups the selection (and any groups it touches). Returns the group ID.
    public static func group(_ ids: [UUID], in project: inout LoftLineProject) -> UUID? {
        let editable = project.document.shapes(ids: ids).filter(project.isEditable).map(\.id)
        return project.document.group(editable)
    }

    public static func ungroup(_ ids: [UUID], in project: inout LoftLineProject) {
        project.document.ungroup(ids)
    }

    /// Equal gaps between neighbours (the outermost two stay put).
    public static func distributeSpacing(_ ids: Set<UUID>, horizontally: Bool, in project: inout LoftLineProject) {
        let shapes = project.document.shapes.filter { ids.contains($0.id) && !$0.isLocked }
        guard shapes.count >= 3 else { return }
        let moved = Alignment.distributeSpacing(shapes, along: horizontally ? .horizontal : .vertical)
        for s in moved { project.document.replace(s) }
    }
}
