import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Envelope distortion on the canvas: drag the four corners of the selection's quad; the
/// vectors are previewed bent to follow. Clicks elsewhere are ignored while the edit is open.
extension CanvasNSView {
    func envelopeMouseDown(_ event: NSEvent, _ doc: LoftLineDocument) -> Bool {
        guard let e = doc.envelopeEdit else { return false }
        let p = docPoint(event, snapped: false)
        drawingState.envelopeCorner = e.corner(at: p, tolerance: handleTolerance)
        return true
    }

    func envelopeMouseDragged(_ event: NSEvent) -> Bool {
        guard let i = drawingState.envelopeCorner, let doc = document, var e = doc.envelopeEdit else { return false }
        let raw = viewport.toDocument(viewPoint(event))
        let p = event.modifierFlags.contains(.command) ? raw : snap(raw, excluding: Set(e.shapeIDs))
        e.move(i, to: p)
        doc.envelopeEdit = e
        needsDisplay = true
        return true
    }

    func drawEnvelope(_ ctx: CGContext, _ doc: LoftLineDocument) {
        guard let e = doc.envelopeEdit else { return }
        ctx.saveGState()
        // Preview: the vectors mapped through the quad.
        let tol = viewport.documentLength(1)
        ctx.setStrokeColor(NSColor.systemPurple.cgColor)
        ctx.setLineWidth(1.5)
        for s in doc.project.document.shapes(ids: e.shapeIDs) {
            for path in s.paths {
                let pts = path.flattened(tolerance: tol).map { viewport.toView(e.map($0)).cg }
                guard pts.count > 1 else { continue }
                ctx.addLines(between: pts)
                if path.isClosed { ctx.closePath() }
            }
        }
        ctx.strokePath()
        // The quad and its corner handles.
        let q = e.quad.map { viewport.toView($0).cg }
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addLines(between: q); ctx.closePath(); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for (i, v) in q.enumerated() {
            let r = CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(drawingState.envelopeCorner == i ? NSColor.systemPurple.cgColor : NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemPurple.cgColor)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }
}
