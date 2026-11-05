import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Guides: drag from a ruler to add, drag a guide to move it, drag it back onto a ruler to
/// delete it. Points snap to guides and line up with existing nodes.
extension CanvasNSView {
    var guides: [GuideLine] { document?.document.guides ?? [] }

    /// Guide/alignment snap for `p` (nil when nothing lines up).
    func axisSnap(_ p: Vec2, grid: Double, excluding: Set<UUID>) -> Vec2? {
        guard let doc = document else { return nil }
        let g = doc.snapToGuides ? guides : []
        let nodes = doc.snapToObjects && doc.snapToGuides
            ? snapEngine(excluding: excluding).targets.filter { $0.kind == .node }.map(\.point) : []
        guard !g.isEmpty || !nodes.isEmpty else { drawingState.axisHint = nil; return nil }
        let r = AxisSnap.snap(p, guides: g, alignWith: nodes, tolerance: snapTolerance, grid: grid)
        guard r.snapped else { drawingState.axisHint = nil; return nil }
        drawingState.axisHint = r
        lastSnap = nil
        return r.point
    }

    // MARK: Mouse

    private func rulerArea(_ v: Vec2) -> (vertical: Bool, hit: Bool) {
        let rs = Double(Self.rulerSize)
        if v.y > Double(bounds.height) - rs, v.x > rs { return (false, true) }
        if v.x < rs, v.y < Double(bounds.height) - rs { return (true, true) }
        return (false, false)
    }

    func guideMouseDown(_ event: NSEvent, _ doc: LoftLineDocument) -> Bool {
        let v = viewPoint(event)
        let ruler = rulerArea(v)
        let p = viewport.toDocument(v)
        if ruler.hit {
            drawingState.guideDrag = (nil, GuideLine(isVertical: ruler.vertical, position: ruler.vertical ? p.x : p.y))
            return true
        }
        guard doc.activeTool == .select, !guides.isEmpty,
              HitTesting.pick(at: p, in: pickableShapes, tolerance: pickTolerance) == nil else { return false }
        let tol = viewport.documentLength(4)
        if let i = guides.firstIndex(where: { abs(($0.isVertical ? p.x : p.y) - $0.position) <= tol }) {
            drawingState.guideDrag = (i, guides[i])
            return true
        }
        return false
    }

    func guideMouseDragged(_ event: NSEvent) -> Bool {
        guard let doc = document, var d = drawingState.guideDrag else { return false }
        let p = viewport.toDocument(viewPoint(event))
        var pos = d.guide.isVertical ? p.x : p.y
        let grid = doc.document.gridSpacing
        if doc.snapToGrid, grid > 0, !event.modifierFlags.contains(.command) { pos = (pos / grid).rounded() * grid }
        d.guide.position = pos
        drawingState.guideDrag = d
        needsDisplay = true
        return true
    }

    func guideMouseUp(_ event: NSEvent) -> Bool {
        guard let doc = document, let d = drawingState.guideDrag else { return false }
        drawingState.guideDrag = nil
        let overRuler = rulerArea(viewPoint(event)).hit
        var list = guides
        if let i = d.index, list.indices.contains(i) {
            if overRuler { list.remove(at: i) } else { list[i] = d.guide }
        } else if !overRuler {
            list.append(d.guide)
        }
        let name = d.index == nil ? "Add Guide" : (overRuler ? "Delete Guide" : "Move Guide")
        doc.perform(name) { $0.document.guides = list.isEmpty ? nil : list }
        needsDisplay = true
        return true
    }

    // MARK: Drawing

    func drawGuides(_ ctx: CGContext, _ doc: LoftLineDocument) {
        var all = guides
        if let d = drawingState.guideDrag {
            if let i = d.index, all.indices.contains(i) { all[i] = d.guide } else { all.append(d.guide) }
        }
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.systemTeal.withAlphaComponent(0.85).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        for g in all { strokeAxisLine(ctx, vertical: g.isVertical, at: g.position) }
        // Alignment hint while drawing/moving.
        if let h = drawingState.axisHint, hoverDoc != nil {
            ctx.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.8).cgColor)
            ctx.setLineDash(phase: 0, lengths: [2, 3])
            if let x = h.x { strokeAxisLine(ctx, vertical: true, at: x) }
            if let y = h.y { strokeAxisLine(ctx, vertical: false, at: y) }
        }
        ctx.restoreGState()
        if let d = drawingState.guideDrag {
            let label = RulerTicks.label((d.guide.position * 1000).rounded() / 1000) + " " + doc.units.abbreviation
            let v = viewport.toView(d.guide.isVertical ? Vec2(d.guide.position, 0) : Vec2(0, d.guide.position))
            let at = d.guide.isVertical ? CGPoint(x: v.x + 4, y: bounds.height - Self.rulerSize - 18)
                                        : CGPoint(x: Self.rulerSize + 4, y: v.y + 3)
            (label as NSString).draw(at: at, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                              .foregroundColor: NSColor.systemTeal])
        }
    }

    private func strokeAxisLine(_ ctx: CGContext, vertical: Bool, at position: Double) {
        let v = viewport.toView(vertical ? Vec2(position, 0) : Vec2(0, position))
        ctx.beginPath()
        if vertical {
            ctx.move(to: CGPoint(x: v.x, y: 0)); ctx.addLine(to: CGPoint(x: v.x, y: bounds.height))
        } else {
            ctx.move(to: CGPoint(x: 0, y: v.y)); ctx.addLine(to: CGPoint(x: bounds.width, y: v.y))
        }
        ctx.strokePath()
    }
}
