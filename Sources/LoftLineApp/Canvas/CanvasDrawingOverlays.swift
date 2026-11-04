import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Overlays for the drawing tools: validator markers.
extension CanvasNSView {
    func drawDrawingOverlays(_ ctx: CGContext, _ doc: LoftLineDocument) {
        drawGuides(ctx, doc)
        drawDimensions(ctx, doc)
        drawHighlightMarkers(ctx, doc)
        if doc.activeTool == .nodeEdit { drawStartMarkers(ctx, doc) }
        drawMeasurement(ctx, doc)
        drawFreehand(ctx)
        drawQuickEntry(doc)
        drawEnvelope(ctx, doc)
        drawKerning(ctx, doc)
    }

    /// Start point and direction of each selected vector (node editing).
    private func drawStartMarkers(_ ctx: CGContext, _ doc: LoftLineDocument) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemGreen.cgColor)
        for s in doc.selectedShapes {
            for p in s.paths where !p.isEmpty {
                let a = viewport.toView(p.start)
                let pts = p.flattened(tolerance: viewport.documentLength(1))
                guard pts.count > 1 else { continue }
                let next = pts.dropFirst().first { viewport.toView($0).distance(to: a) > 0.5 } ?? pts[1]
                let d = (viewport.toView(next) - a).normalized
                let n = d.perpendicular
                // Small arrow just ahead of the start node, pointing along the path.
                let tip = a + d * 16, base = a + d * 7
                ctx.beginPath()
                ctx.move(to: CGPoint(x: tip.x, y: tip.y))
                ctx.addLine(to: CGPoint(x: base.x + n.x * 4, y: base.y + n.y * 4))
                ctx.addLine(to: CGPoint(x: base.x - n.x * 4, y: base.y - n.y * 4))
                ctx.closePath()
                ctx.fillPath()
                ctx.fillEllipse(in: CGRect(x: a.x - 2.5, y: a.y - 2.5, width: 5, height: 5))
            }
        }
        ctx.restoreGState()
    }

    private func drawHighlightMarkers(_ ctx: CGContext, _ doc: LoftLineDocument) {
        guard !doc.highlightMarkers.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(2)
        for p in doc.highlightMarkers {
            let v = viewport.toView(p)
            ctx.strokeEllipse(in: CGRect(x: v.x - 9, y: v.y - 9, width: 18, height: 18))
        }
        ctx.restoreGState()
    }
}
