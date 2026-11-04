// 2D toolpath overlay drawing helpers (rapids dashed, cuts coloured by depth).
// Owned by the preview workstream; the canvas calls `ToolpathOverlayRenderer.draw`.
import AppKit
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

struct ToolpathOverlayStyle {
    var cutLineWidth: CGFloat = 1.5
    var rapidLineWidth: CGFloat = 0.75
    var rapidColor = CGColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 0.75)
    var rapidDash: [CGFloat] = [4, 3]
    var showRapids = true
    var plungeRadius: CGFloat = 3
    /// Toolpaths (by index) drawn faded, e.g. those not selected.
    var dimmedToolpaths: Set<Int> = []
}

enum ToolpathOverlayRenderer {
    static func color(for depth: Double, maxDepth: Double, alpha: CGFloat = 1) -> CGColor {
        let c = DepthColorRamp.toolpath(normalizedDepth: maxDepth > 0 ? depth / maxDepth : 0)
        return CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: alpha)
    }

    /// Draws `overlay` into `ctx`. `transform` maps the material frame (document units,
    /// y up) to the context's coordinates; line widths stay in context points.
    /// `depthScale` is the depth that maps to the deepest colour (defaults to the overlay's own).
    static func draw(_ overlay: ToolpathOverlay, in ctx: CGContext, transform: CGAffineTransform,
                     style: ToolpathOverlayStyle = ToolpathOverlayStyle(), depthScale: Double? = nil) {
        let maxDepth = depthScale ?? overlay.maxDepth
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func path(_ pts: [Vec2]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y).applying(transform) })
            return p
        }

        if style.showRapids {
            ctx.setStrokeColor(style.rapidColor)
            ctx.setLineWidth(style.rapidLineWidth)
            ctx.setLineDash(phase: 0, lengths: style.rapidDash)
            for s in overlay.strokes where s.isRapid && !style.dimmedToolpaths.contains(s.toolpathIndex) {
                ctx.addPath(path(s.points))
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }

        ctx.setLineWidth(style.cutLineWidth)
        for s in overlay.strokes where !s.isRapid {
            let alpha: CGFloat = style.dimmedToolpaths.contains(s.toolpathIndex) ? 0.2 : 1
            ctx.setStrokeColor(color(for: s.depth, maxDepth: maxDepth, alpha: alpha))
            ctx.addPath(path(s.points))
            ctx.strokePath()
        }

        for p in overlay.plunges {
            let alpha: CGFloat = style.dimmedToolpaths.contains(p.toolpathIndex) ? 0.2 : 1
            let c = CGPoint(x: p.point.x, y: p.point.y).applying(transform)
            let r = style.plungeRadius
            ctx.setStrokeColor(color(for: p.depth, maxDepth: maxDepth, alpha: alpha))
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Transform fitting `bounds` (material frame, y up) into `size` (y down) with `margin`.
    static func fitTransform(bounds: Rect2, in size: CGSize, margin: CGFloat = 16) -> CGAffineTransform {
        let w = CGFloat(max(bounds.width, 1e-9)), h = CGFloat(max(bounds.height, 1e-9))
        let s: CGFloat = min((size.width - 2 * margin) / w, (size.height - 2 * margin) / h)
        let scale: CGFloat = max(s, 1e-6)
        let ox: CGFloat = (size.width - w * scale) / 2 - CGFloat(bounds.min.x) * scale
        let oy: CGFloat = (size.height + h * scale) / 2 + CGFloat(bounds.min.y) * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: ox, ty: oy)
    }
}

/// Standalone 2D toolpath preview: material outline, design vectors and toolpath overlay.
struct ToolpathOverlayView: View {
    var document: Document
    var toolpaths: [Toolpath]
    var showRapids = true

    var body: some View {
        let overlay = ToolpathOverlay(toolpaths: toolpaths, coords: MachineCoordinates(job: document.job))
        Canvas { context, size in
            let bounds = document.job.materialBounds
            let t = ToolpathOverlayRenderer.fitTransform(bounds: bounds, in: size)
            context.withCGContext { cg in
                // Stock.
                cg.setFillColor(CGColor(red: 0.93, green: 0.85, blue: 0.70, alpha: 1))
                cg.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
                let r = CGRect(x: bounds.min.x, y: bounds.min.y, width: bounds.width, height: bounds.height)
                    .applying(t)
                cg.fill(r)
                cg.stroke(r, width: 1)
                // Design vectors.
                cg.setStrokeColor(CGColor(gray: 0.15, alpha: 0.6))
                cg.setLineWidth(0.75)
                for shape in document.shapes {
                    for p in shape.paths {
                        let pts = p.flattened(tolerance: 0.005)
                        guard pts.count >= 2 else { continue }
                        let cg2 = CGMutablePath()
                        cg2.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y).applying(t) })
                        if p.isClosed { cg2.closeSubpath() }
                        cg.addPath(cg2)
                        cg.strokePath()
                    }
                }
                var style = ToolpathOverlayStyle()
                style.showRapids = showRapids
                ToolpathOverlayRenderer.draw(overlay, in: cg, transform: t, style: style)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
