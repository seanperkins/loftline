import AppKit
import CADCore
import CAMCore
import LoftLineKit

extension Transform2D {
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

/// Selection handles, node/handle markers, pen preview and snap markers.
extension CanvasNSView {
    /// Transform previewed on the selection while moving or dragging a handle.
    var selectionPreviewTransform: Transform2D? {
        switch drag {
        case .move(let s, let c): return .translation(snappedDelta(c - s))
        case .handle(let h, let box, let s, let c): return handleTransform(h, box: box, from: s, to: c, flags: NSEvent.modifierFlags)
        default: return nil
        }
    }

    /// Shapes as they will look after the node/handle drag in progress (keyed by shape ID).
    var nodeDragPreview: [UUID: Shape] {
        guard let doc = document else { return [:] }
        switch drag {
        case .nodes(let anchor, let s, let c):
            let d = nodeDragDelta(anchor: anchor, start: s, current: c, flags: NSEvent.modifierFlags)
            var out: [UUID: Shape] = [:]
            for id in Set(doc.nodeSelection.map(\.shapeID)) {
                if let shape = doc.project.document.shape(id: id) {
                    out[id] = NodeMirror.moveNodes(shape, doc.nodeSelection, by: d, mode: doc.drawingOptions.nodeMirror)
                }
            }
            return out
        case .bezierHandle(let r, let h, let c):
            return previewHandleDrag(r, h, to: c, flags: NSEvent.modifierFlags).map { [r.shapeID: $0] } ?? [:]
        default:
            return [:]
        }
    }

    func drawEditingOverlay(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        switch doc.activeTool {
        case .select: drawTransformHandles(ctx)
        case .nodeEdit: drawNodes(ctx, doc)
        case .pen: drawPen(ctx, vt)
        default: break
        }
        if case .nodeMarquee(let a, let b, _) = drag {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.saveGState()
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.stroke(r)
            ctx.restoreGState()
        }
        drawSnapMarker(ctx)
    }

    private func drawTransformHandles(_ ctx: CGContext) {
        guard let box = transformBox else { return }
        let shown: Rect2
        if case .handle(let h, let b, let s, let c) = drag {
            let t = handleTransform(h, box: b, from: s, to: c, flags: NSEvent.modifierFlags)
            shown = h == .rotate ? box : Rect2(points: [t.apply(b.min), t.apply(b.max)])
        } else {
            shown = box
        }
        let r = viewRect(shown)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        let positions = TransformHandles.positions(for: shown, rotateOffset: rotateHandleOffset)
        if let top = positions[.top], let rot = positions[.rotate] {
            ctx.move(to: viewport.toView(top).cg); ctx.addLine(to: viewport.toView(rot).cg); ctx.strokePath()
        }
        for (h, p) in positions {
            let v = viewport.toView(p)
            let rect = CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            if h == .rotate { ctx.fillEllipse(in: rect); ctx.strokeEllipse(in: rect) } else { ctx.fill(rect); ctx.stroke(rect) }
        }
        ctx.restoreGState()
        if case .handle(.rotate, let b, let s, let c) = drag {
            let t = handleTransform(.rotate, box: b, from: s, to: c, flags: NSEvent.modifierFlags)
            let deg = atan2(t.b, t.a) * 180 / .pi
            label(String(format: "%.1f°", deg), at: viewport.toView(c))
        } else if case .handle(_, _, _, let c) = drag {
            label(RulerTicks.label((shown.width * 1000).rounded() / 1000) + " × "
                  + RulerTicks.label((shown.height * 1000).rounded() / 1000), at: viewport.toView(c))
        }
    }

    private func drawNodes(_ ctx: CGContext, _ doc: LoftLineDocument) {
        let preview = nodeDragPreview
        ctx.saveGState()
        ctx.setLineWidth(1)
        drawMirrorAxes(ctx, doc.drawingOptions.nodeMirror)
        for original in nodeTargets {
            let s = ShapeNodes.editable(preview[original.id] ?? original)
            for (pi, p) in s.paths.enumerated() {
                let n = PathNodes.anchorCount(p)
                guard n < 5000 else { continue }
                for k in 0..<n {
                    let a = viewport.toView(PathNodes.anchor(p, k))
                    let ref = NodeRef(shapeID: s.id, path: pi, node: k)
                    let selected = doc.nodeSelection.contains(ref)
                    // Handles: shown for selected nodes and their neighbours' adjoining handles.
                    for h in [PathNodes.Handle.incoming, .outgoing] {
                        guard let hp = PathNodes.handle(p, k, h) else { continue }
                        let v = viewport.toView(hp)
                        ctx.setStrokeColor(NSColor.systemGray.cgColor)
                        ctx.move(to: a.cg); ctx.addLine(to: v.cg); ctx.strokePath()
                        let r = CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)
                        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: r)
                        ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.strokeEllipse(in: r)
                    }
                    let r = CGRect(x: a.x - 3.5, y: a.y - 3.5, width: 7, height: 7)
                    ctx.setFillColor(selected ? NSColor.systemOrange.cgColor : NSColor.white.cgColor)
                    ctx.fill(r)
                    ctx.setStrokeColor(k == 0 ? NSColor.systemGreen.cgColor : NSColor.systemOrange.cgColor)
                    ctx.stroke(r)
                }
            }
        }
        ctx.restoreGState()
    }

    /// Dashed centre lines of each edited shape while mirror mode is on.
    private func drawMirrorAxes(_ ctx: CGContext, _ mode: NodeMirrorMode) {
        guard mode != .off else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPurple.withAlphaComponent(0.7).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        for s in nodeTargets {
            let b = s.bounds()
            guard !b.isEmpty else { continue }
            let c = b.center, pad = viewport.documentLength(12)
            if mode != .topBottom {
                ctx.move(to: viewport.toView(Vec2(c.x, b.min.y - pad)).cg); ctx.addLine(to: viewport.toView(Vec2(c.x, b.max.y + pad)).cg)
            }
            if mode != .leftRight {
                ctx.move(to: viewport.toView(Vec2(b.min.x - pad, c.y)).cg); ctx.addLine(to: viewport.toView(Vec2(b.max.x + pad, c.y)).cg)
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawPen(_ ctx: CGContext, _ vt: CGAffineTransform) {
        guard !pen.isEmpty else { return }
        var preview = pen
        if case .penDrag = drag {} else if let h = hoverDoc { preview.addNode(h) }
        if let p = preview.path(closed: false) {
            stroke(ctx, CanvasPaths.cgPath(for: p), vt, color: .systemBlue, width: 1.5)
        }
        ctx.saveGState()
        for n in pen.nodes {
            let a = viewport.toView(n.point)
            if let o = n.handleOut, let i = n.handleIn {
                ctx.setStrokeColor(NSColor.systemGray.cgColor)
                ctx.move(to: viewport.toView(i).cg); ctx.addLine(to: viewport.toView(o).cg); ctx.strokePath()
                for hp in [i, o] {
                    let v = viewport.toView(hp)
                    ctx.setFillColor(NSColor.systemOrange.cgColor)
                    ctx.fillEllipse(in: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6))
                }
            }
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6))
        }
        ctx.restoreGState()
    }

    private func drawSnapMarker(_ ctx: CGContext) {
        guard let s = lastSnap, s.kind != .none, s.kind != .grid else { return }
        let v = viewport.toView(s.point)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPink.cgColor)
        ctx.setLineWidth(1.5)
        let r = CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)
        switch s.kind {
        case .node: ctx.stroke(r)
        case .midpoint:
            ctx.move(to: CGPoint(x: r.midX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            ctx.addLine(to: CGPoint(x: r.minX, y: r.minY)); ctx.closePath(); ctx.strokePath()
        default: ctx.strokeEllipse(in: r)
        }
        ctx.restoreGState()
    }

    private func label(_ text: String, at v: Vec2) {
        (text as NSString).draw(at: CGPoint(x: v.x + 12, y: v.y + 8),
                                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                 .foregroundColor: NSColor.systemBlue,
                                                 .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.8)])
    }
}
