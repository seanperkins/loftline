import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Layout overlays on the design canvas: clamp / keep-out zones and the outlines of nesting
/// sheets parked beside the material.
extension CanvasNSView {
    func drawLayoutOverlay(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        drawClampZones(ctx, doc, vt)
        drawSheetSlots(ctx, doc, vt)
    }

    /// Clamp / keep-out zones: translucent red fill under their outlines.
    private func drawClampZones(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let d = doc.document
        let layers = d.layers.filter { $0.keepOut != nil && $0.isVisible }
        guard !layers.isEmpty else { return }
        let ids = Set(layers.map(\.id))
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
        for s in d.shapes where ids.contains(s.layerID) && s.isClosed {
            var t = vt
            guard let p = cgPath(s).copy(using: &t) else { continue }
            ctx.addPath(p)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
    }

    private func drawSheetSlots(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let d = doc.document
        guard NestSheets.hasSheets(d) else { return }
        let active = NestSheets.activeSheet(in: d)
        let material = d.job.materialBounds
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for n in NestSheets.numbers(in: d) {
            let off = NestSheets.offset(ofSheet: n, in: d)
            let r = viewRect(Rect2(min: material.min + off, max: material.max + off))
            if n != active {
                ctx.saveGState()
                NSColor(srgbRed: 0.99, green: 0.97, blue: 0.93, alpha: 0.55).setFill()
                ctx.fill(r)
                ctx.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.45, blue: 0.33, alpha: 1).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
                ctx.restoreGState()
            }
            let label = n == active ? "Sheet \(n) — on the material" : "Sheet \(n) — parked (not cut)"
            (label as NSString).draw(at: CGPoint(x: r.minX, y: r.maxY + 4), withAttributes: attrs)
        }
    }
}
