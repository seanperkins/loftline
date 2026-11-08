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

    /// Clamp / keep-out zones: translucent red fill under their outlines. The fill is the closed loops the export checks
    /// (`ClampList`), so a shape mixing closed and open paths fills its closed ones, and every named clamp has its fill.
    private func drawClampZones(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let d = doc.document
        let items = clampCache.items(in: d).filter { item in item.layerID.map { d.layer(id: $0)?.isVisible ?? false } ?? false }
        guard !items.isEmpty else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.18).cgColor)
        for item in items {
            let p = CGMutablePath()
            for loop in item.loops {
                p.addLines(between: loop.map { CGPoint(x: $0.x, y: $0.y).applying(vt) })
                p.closeSubpath()
            }
            ctx.addPath(p)
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
    }

    /// Each drawn clamp's name at its centre, numbered as the job sheet and the 3D preview number it (`ClampList`, issue #134).
    /// Zones on hidden keep-out layers aren't drawn, so they aren't named here; the job sheet still lists them.
    func drawClampNames(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let d = doc.document
        let items = clampCache.items(in: d).filter { item in item.layerID.map { d.layer(id: $0)?.isVisible ?? false } ?? true }
        guard !items.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.systemRed]
        for item in items {
            let c = CGPoint(x: item.labelPoint.x, y: item.labelPoint.y).applying(vt)
            let text = item.name as NSString
            let size = text.size(withAttributes: attrs)
            let box = CGRect(x: c.x - size.width / 2 - 3, y: c.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
            ctx.saveGState()
            ctx.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.85).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            text.draw(at: CGPoint(x: box.minX + 3, y: box.minY + 1), withAttributes: attrs)
        }
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
