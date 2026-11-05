import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Node-edit and Bézier-pen interaction.
///
/// Node tool: click a shape to edit it; click/drag nodes (Shift adds to the node selection),
/// drag Bézier handles (Option breaks a smooth node), double-click a segment to insert a node,
/// drag on empty space to rubber-band nodes.
extension CanvasNSView {
    /// Shapes whose nodes are shown and editable: the editable part of the selection.
    var nodeTargets: [Shape] {
        guard let doc = document else { return [] }
        return doc.selectedShapes.filter { doc.project.isEditable($0) }
    }

    func nodeHit(at p: Vec2) -> NodeRef? {
        for s in nodeTargets.reversed() {
            if let r = ShapeNodes.hitNode(s, at: p, tolerance: handleTolerance) { return r }
        }
        return nil
    }

    func nodeMouseDown(_ event: NSEvent) {
        guard let doc = document else { return }
        let v = viewPoint(event)
        let p = docPoint(event, snapped: false)
        let extend = event.modifierFlags.contains(.shift)
        for s in nodeTargets.reversed() {
            if let (r, h) = ShapeNodes.hitHandle(s, at: p, tolerance: handleTolerance) {
                drag = .bezierHandle(r, h, currentDoc: p)
                return
            }
        }
        if let r = nodeHit(at: p) {
            if extend {
                if doc.nodeSelection.contains(r) { doc.nodeSelection.remove(r) } else { doc.nodeSelection.insert(r) }
            } else if !doc.nodeSelection.contains(r) {
                doc.nodeSelection = [r]
            }
            guard doc.nodeSelection.contains(r), let anchor = doc.project.nodePosition(r) else { return }
            drag = .nodes(anchor: anchor, startDoc: p, currentDoc: p)
            return
        }
        for s in nodeTargets.reversed() {
            guard let (seg, t) = ShapeNodes.hitSegment(s, at: p, tolerance: pickTolerance) else { continue }
            if event.clickCount >= 2 {
                doc.replaceShape(ShapeNodes.insertNode(s, seg, t: t), actionName: "Insert Node")
                doc.nodeSelection = [NodeRef(shapeID: s.id, path: seg.path, node: seg.segment + 1)]
            } else if !extend {
                doc.nodeSelection = []
            }
            return
        }
        if let hit = HitTesting.pick(at: p, in: pickableShapes, tolerance: pickTolerance) {
            doc.select(hit, extending: extend)
            if !extend { doc.nodeSelection = [] }
            return
        }
        drag = .nodeMarquee(startView: v, currentView: v, extend: extend)
    }

    func nodeMouseDragged(_ event: NSEvent) {
        let v = viewPoint(event)
        switch drag {
        case .nodes(let anchor, let s, _):
            drag = .nodes(anchor: anchor, startDoc: s, currentDoc: viewport.toDocument(v))
        case .bezierHandle(let r, let h, _):
            drag = .bezierHandle(r, h, currentDoc: docPoint(event, excluding: [r.shapeID]))
        case .nodeMarquee(let s, _, let extend):
            drag = .nodeMarquee(startView: s, currentView: v, extend: extend)
        case .penDrag:
            pen.dragLastHandle(to: docPoint(event), minLength: viewport.documentLength(2))
        default:
            break
        }
    }

    func nodeMouseUp(_ event: NSEvent) {
        guard let doc = document else { return }
        switch drag {
        case .nodes(let anchor, let s, let c):
            doc.moveSelectedNodes(by: nodeDragDelta(anchor: anchor, start: s, current: c, flags: event.modifierFlags))
        case .bezierHandle(let r, let h, let c):
            if let shape = previewHandleDrag(r, h, to: c, flags: event.modifierFlags) {
                doc.replaceShape(shape, actionName: "Move Handle")
            }
        case .nodeMarquee(let a, let b, let extend):
            let rect = Rect2(points: [viewport.toDocument(a), viewport.toDocument(b)])
            let hits = Set(nodeTargets.flatMap { ShapeNodes.nodes(of: $0) }.filter { rect.contains($0.point) }.map(\.ref))
            doc.nodeSelection = extend ? doc.nodeSelection.union(hits) : hits
        default:
            break
        }
    }

    /// Delta for a node drag: the grabbed node snaps to objects/grid (Command disables).
    func nodeDragDelta(anchor: Vec2, start: Vec2, current: Vec2, flags: NSEvent.ModifierFlags) -> Vec2 {
        let target = anchor + (current - start)
        guard !flags.contains(.command), let doc = document else { return current - start }
        let excluded = Set(doc.nodeSelection.map(\.shapeID))
        return snap(target, excluding: excluded) - anchor
    }

    /// Shape after dragging a handle; smooth nodes stay smooth unless Option is held.
    func previewHandleDrag(_ r: NodeRef, _ h: PathNodes.Handle, to p: Vec2, flags: NSEvent.ModifierFlags) -> Shape? {
        guard let s = document?.project.document.shape(id: r.shapeID) else { return nil }
        let e = ShapeNodes.editable(s)
        guard e.paths.indices.contains(r.path) else { return nil }
        let smooth = PathNodes.isSmooth(e.paths[r.path], r.node) && !flags.contains(.option)
        return NodeMirror.moveHandle(e, r, h, to: p, keepSmooth: smooth, mode: document?.drawingOptions.nodeMirror ?? .off)
    }

    // MARK: Pen

    func penMouseDown(_ event: NSEvent) {
        let p = docPoint(event)
        if pen.closes(at: p, tolerance: viewport.documentLength(8)) { finishClickShape(closed: true); return }
        if event.clickCount >= 2, !pen.isEmpty { finishClickShape(); return }
        pen.addNode(p)
        drag = .penDrag
    }
}
