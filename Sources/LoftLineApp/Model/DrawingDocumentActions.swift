import CADCore
import CAMCore
import Foundation
import LoftLineKit

/// Undoable drawing actions on the focused document (node-edit extras etc.).
extension LoftLineDocument {
    /// Finds vectors lying on top of others (selection, or the whole design) and deletes the
    /// extra copies, then reports how many went.
    func deleteDuplicateVectors() {
        let scope = VectorCommands.validationScope(selectedShapes.map(\.id), in: project)
        let dups = VectorValidator.duplicates(scope, tolerance: VectorCommands.tolerance(units))
        var removed = 0
        if !dups.isEmpty { perform("Delete Duplicates") { removed = VectorCommands.repair(dups, in: &$0) } }
        report(AlertMessage(title: "Duplicate Vectors",
                             message: removed == 0 ? "No duplicate or overlapping vectors found."
                                 : "Deleted \(removed) duplicate or overlapping vector\(removed == 1 ? "" : "s")."))
    }

    /// Lines the selected nodes up on their average X (`vertical` line) or Y.
    func alignSelectedNodes(onX: Bool) {
        let refs = nodeSelection
        guard refs.count >= 2 else { return }
        let pts = refs.compactMap { r in project.nodePosition(r).map { (r, $0) } }
        guard !pts.isEmpty else { return }
        let target = pts.reduce(0) { $0 + (onX ? $1.1.x : $1.1.y) } / Double(pts.count)
        perform(onX ? "Align Nodes X" : "Align Nodes Y") { p in
            for (r, q) in pts {
                let d = onX ? Vec2(target - q.x, 0) : Vec2(0, target - q.y)
                if d != .zero { p.moveNodes([r], by: d) }
            }
        }
    }

    /// Turns the segment after each selected node into a circular arc.
    func convertSpansToArcs() {
        let refs = nodeSelection.sorted { ($0.path, $0.node) > ($1.path, $1.node) }
        guard !refs.isEmpty else { return }
        perform("Convert to Arc") { p in
            for r in refs {
                p.editNodes(of: r.shapeID) { s in
                    let e = ShapeNodes.editable(s)
                    guard e.paths.indices.contains(r.path), let seg = PathNodes.outgoingSegment(e.paths[r.path], r.node),
                          let np = PathNodes.spanToArc(e.paths[r.path], segment: seg) else { return nil }
                    var c = e
                    c.paths[r.path] = np
                    return c
                }
            }
        }
        nodeSelection = []
    }

    /// Makes the single selected node the start of its closed vector.
    func setStartAtSelectedNode() {
        guard nodeSelection.count == 1, let r = nodeSelection.first else { return }
        var ok = false
        perform("Set Start Point") { ok = $0.editNodes(of: r.shapeID) { ShapeNodes.settingStart($0, r) } }
        if ok { nodeSelection = [NodeRef(shapeID: r.shapeID, path: r.path, node: 0)] }
    }
}
