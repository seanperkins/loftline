import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Dimension tool: clicks build reference dimensions, which are drawn on top of the design.
extension CanvasNSView {
    func dimensionClick(_ event: NSEvent, _ doc: LoftLineDocument) {
        let kind = doc.drawingOptions.dimensionKind
        if kind == .radius || kind == .diameter {
            let p = docPoint(event, snapped: false)
            let visible = flatShapes(doc.project.document.shapes.filter { doc.project.isVisible($0) })
            guard let id = HitTesting.pick(at: p, in: visible, tolerance: pickTolerance), let s = doc.document.shape(id: id) else {
                NSSound.beep(); return
            }
            let m = Measurement.vector(s, at: p, tolerance: tolerance)
            guard let c = m.center, let r = m.radius,
                  let d = DimensionBuilder.radial(kind, center: c, radius: r, toward: p) else { NSSound.beep(); return }
            add(d, doc)
            return
        }
        clickPoints.append(docPoint(event))
        if clickPoints.count >= DimensionBuilder.clicksNeeded(kind) {
            if let d = DimensionBuilder.make(kind, clicks: clickPoints) { add(d, doc) } else { NSSound.beep() }
            clickPoints = []
        }
    }

    private func add(_ d: DimensionAnnotation, _ doc: LoftLineDocument) {
        doc.perform("Add Dimension") { $0.document.dimensions = ($0.document.dimensions ?? []) + [d] }
    }

    // MARK: Drawing

    func drawDimensions(_ ctx: CGContext, _ doc: LoftLineDocument) {
        var all = doc.document.dimensions ?? []
        // Preview of the one being placed.
        if doc.activeTool == .dimension, !clickPoints.isEmpty, let h = hoverDoc {
            let kind = doc.drawingOptions.dimensionKind
            let pts = clickPoints + [h]
            if pts.count >= 3, let d = DimensionBuilder.make(kind, clicks: pts) {
                all.append(d)
            } else if pts.count == 2, kind != .angle {
                all.append(DimensionAnnotation(kind: kind, points: pts))
            }
        }
        guard !all.isEmpty else { return }
        ctx.saveGState()
        let color = NSColor.systemPurple
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1)
        for d in all { drawDimension(ctx, d, doc.units, color) }
        ctx.restoreGState()
    }

    private func v(_ p: Vec2) -> CGPoint { let q = viewport.toView(p); return CGPoint(x: q.x, y: q.y) }

    private func line(_ ctx: CGContext, _ a: Vec2, _ b: Vec2) {
        ctx.beginPath(); ctx.move(to: v(a)); ctx.addLine(to: v(b)); ctx.strokePath()
    }

    /// Arrowhead at `tip` pointing away from `from` (screen-sized).
    private func arrow(_ ctx: CGContext, tip: Vec2, from: Vec2) {
        let t = viewport.toView(tip), f = viewport.toView(from)
        let d = (t - f).normalized, n = d.perpendicular
        guard d != .zero else { return }
        let base = t - d * 8
        ctx.beginPath()
        ctx.move(to: CGPoint(x: t.x, y: t.y))
        ctx.addLine(to: CGPoint(x: base.x + n.x * 3, y: base.y + n.y * 3))
        ctx.addLine(to: CGPoint(x: base.x - n.x * 3, y: base.y - n.y * 3))
        ctx.closePath()
        ctx.fillPath()
    }

    private func text(_ s: String, at p: Vec2, _ color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: color,
                                                    .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.75)]
        let size = (s as NSString).size(withAttributes: attrs)
        let c = viewport.toView(p)
        (s as NSString).draw(at: CGPoint(x: c.x - size.width / 2, y: c.y + 2), withAttributes: attrs)
    }

    private func drawDimension(_ ctx: CGContext, _ d: DimensionAnnotation, _ units: LengthUnit, _ color: NSColor) {
        let label = DimensionBuilder.label(d, units: units)
        switch d.kind {
        case .aligned, .horizontal, .vertical:
            guard let (a, b) = d.dimensionLine else { return }
            line(ctx, d.points[0], a)
            line(ctx, d.points[1], b)
            line(ctx, a, b)
            arrow(ctx, tip: a, from: b)
            arrow(ctx, tip: b, from: a)
            text(label, at: (a + b) / 2, color)
        case .radius, .diameter:
            guard d.points.count >= 2 else { return }
            let c = d.points[0], p = d.points[1]
            let start = d.kind == .diameter ? c - (p - c) : c
            line(ctx, start, p)
            arrow(ctx, tip: p, from: c)
            if d.kind == .diameter { arrow(ctx, tip: start, from: c) }
            text(label, at: c.lerp(to: p, 0.5), color)
        case .angle:
            guard d.points.count >= 3 else { return }
            let o = d.points[0], a = d.points[1], b = d.points[2]
            line(ctx, o, a)
            line(ctx, o, b)
            let a0 = (a - o).angle
            var sweep = (b - o).angle - a0
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            ctx.beginPath()
            let n = 24
            for i in 0...n {
                let ang = a0 + sweep * Double(i) / Double(n)
                let q = v(o + Vec2(cos(ang), sin(ang)) * d.offset)
                if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
            }
            ctx.strokePath()
            let mid = a0 + sweep / 2
            text(label, at: o + Vec2(cos(mid), sin(mid)) * d.offset, color)
        }
    }
}
