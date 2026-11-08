import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Canvas colours chosen in Preferences (with built-in fallbacks).
enum CanvasColors {
    static var prefs: AppPreferences { PreferencesModel.shared.prefs }
    static var material: NSColor { NSColor(hex: prefs.materialColorHex) ?? NSColor(hex: AppPreferences.defaultMaterialColor)! }
    static var selection: NSColor { NSColor(hex: prefs.selectionColorHex) ?? .systemBlue }
    static var rapid: NSColor { NSColor(hex: prefs.rapidColorHex) ?? .systemRed }
}

/// Palette for toolpath overlays (one colour per operation, cycling).
enum ToolpathColors {
    static let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal,
                                     .systemPink, .systemBrown, .systemIndigo]
    static func color(forIndex i: Int) -> NSColor { palette[i % palette.count] }
}

extension CanvasNSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let doc = document else { return }
        pruneCaches()
        let vt = viewTransform

        drawMaterial(ctx, doc, vt)
        PlacedImageRenderer.drawAll(doc.document, in: ctx, transform: vt)
        drawLayoutOverlay(ctx, doc, vt)
        drawGrid(ctx, doc)
        drawModels(ctx, doc, vt)
        drawOtherSide(ctx, doc, vt)
        drawKeepOutZones(ctx, doc, vt)
        drawShapes(ctx, doc, vt)
        if doc.showToolpaths { drawToolpaths(ctx, doc, vt) }
        drawTabs(ctx, doc, vt)
        drawClampNames(ctx, doc, vt)
        drawOrigin(ctx, doc)
        drawInteraction(ctx, doc, vt)
        drawEditingOverlay(ctx, doc, vt)
        drawDrawingOverlays(ctx, doc)
        drawRulers(ctx, doc)
        drawCursorReadout(doc)
    }

    /// Document → view affine transform.
    var viewTransform: CGAffineTransform {
        CGAffineTransform(a: viewport.scale, b: 0, c: 0, d: viewport.scale, tx: viewport.offset.x, ty: viewport.offset.y)
    }

    func viewRect(_ r: Rect2) -> CGRect {
        let a = viewport.toView(r.min), b = viewport.toView(r.max)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    func stroke(_ ctx: CGContext, _ path: CGPath, _ t: CGAffineTransform, color: NSColor, width: CGFloat,
                        dash: [CGFloat] = []) {
        var tt = t
        guard let p = path.copy(using: &tt) else { return }
        ctx.saveGState()
        ctx.addPath(p)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Layers of the drawing

    private func drawMaterial(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let r = viewRect(doc.document.job.materialBounds)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        CanvasColors.material.setFill()
        ctx.fill(r)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(srgbRed: 0.55, green: 0.45, blue: 0.33, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawGrid(_ ctx: CGContext, _ doc: LoftLineDocument) {
        let mat = doc.document.job.materialBounds
        let grid = doc.document.gridSpacing
        guard grid > 0 else { return }
        var step = grid
        while step * viewport.scale < 8 { step *= 2 }
        let clip = viewRect(mat)
        ctx.saveGState()
        ctx.clip(to: clip)
        let major = RulerTicks.majorStep(scale: viewport.scale, units: doc.units)
        for (lines, color) in [(RulerTicks.values(from: mat.min.x, to: mat.max.x, step: step), 0.06),
                               (RulerTicks.values(from: mat.min.x, to: mat.max.x, step: major), 0.12)] {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(color).cgColor)
            ctx.setLineWidth(1)
            for x in lines {
                let vx = (viewport.toView(Vec2(x, 0)).x).rounded() + 0.5
                ctx.move(to: CGPoint(x: vx, y: clip.minY)); ctx.addLine(to: CGPoint(x: vx, y: clip.maxY))
            }
            ctx.strokePath()
        }
        for (lines, color) in [(RulerTicks.values(from: mat.min.y, to: mat.max.y, step: step), 0.06),
                               (RulerTicks.values(from: mat.min.y, to: mat.max.y, step: major), 0.12)] {
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(color).cgColor)
            for y in lines {
                let vy = (viewport.toView(Vec2(0, y)).y).rounded() + 0.5
                ctx.move(to: CGPoint(x: clip.minX, y: vy)); ctx.addLine(to: CGPoint(x: clip.maxX, y: vy))
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawModels(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        for m in doc.document.models {
            guard let b = m.mesh.bounds else { continue }
            let r = Rect2(min: Vec2(b.min.x, b.min.y) * m.scale + m.offset, max: Vec2(b.max.x, b.max.y) * m.scale + m.offset)
            let vr = viewRect(r)
            ctx.saveGState()
            ctx.setFillColor(NSColor.systemGray.withAlphaComponent(0.15).cgColor)
            ctx.fill(vr)
            ctx.setStrokeColor(NSColor.systemGray.cgColor)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.stroke(vr)
            ctx.restoreGState()
            ("3D: " + m.name as NSString).draw(at: CGPoint(x: vr.minX + 4, y: vr.maxY - 16),
                                               withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                                                .foregroundColor: NSColor.darkGray])
        }
    }

    private func drawShapes(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let project = doc.project
        let preview = selectionPreviewTransform
        let nodePreview = nodeDragPreview
        let selected = doc.selection
        let shown = project.document.shapes.filter { project.isVisible($0) && doc.isOnActiveSide($0) }
        if CanvasDetail.usesHairlines(segmentCount: CanvasDetail.segmentCount(of: shown)) {
            drawShapesAsHairlines(ctx, doc, vt, shown, selected: selected, preview: preview, nodePreview: nodePreview)
            return
        }
        for s in shown {
            let layer = project.document.layer(id: s.layerID)
            let base = NSColor(hex: layer?.colorHex ?? "#000000") ?? .black
            let path = cgPath(s)
            let isSel = selected.contains(s.id)
            let locked = !project.isEditable(s)
            stroke(ctx, path, vt, color: locked ? base.withAlphaComponent(0.45) : base, width: isSel ? 1 : 1.25)
            if isSel {
                stroke(ctx, path, vt, color: CanvasColors.selection, width: 2, dash: doc.activeTool == .nodeEdit ? [] : [6, 4])
                if let t = preview, project.isEditable(s) {
                    stroke(ctx, path, t.cg.concatenating(vt), color: CanvasColors.selection.withAlphaComponent(0.6), width: 1.5)
                }
            }
            if let ps = nodePreview[s.id] {
                stroke(ctx, CanvasPaths.cgPath(for: ps), vt, color: .systemBlue.withAlphaComponent(0.7), width: 1.5)
            }
        }
    }

    /// The shapes of a drawing too big for the full stroker (`CanvasDetail`): one point wide, one color each, those out of
    /// view skipped. The state is set once for all of them (a width of exactly one point, the default join and cap, no
    /// dash) and only the color changes from shape to shape.
    private func drawShapesAsHairlines(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform, _ shapes: [Shape],
                                       selected: Set<UUID>, preview: Transform2D?, nodePreview: [UUID: Shape]) {
        let project = doc.project
        CanvasDetail.hairlineDraws += 1
        var layerColors: [UUID: NSColor] = [:]
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)
        ctx.setLineDash(phase: 0, lengths: [])
        for s in shapes {
            let path = cgPath(s)
            let box = path.boundingBoxOfPath
            let isSel = selected.contains(s.id)
            // Where it is, and where a drag in progress would put it: each is drawn when it can be seen.
            if CanvasDetail.isVisible(box.applying(vt), in: bounds) {
                var color = CanvasColors.selection
                if !isSel {
                    if layerColors[s.layerID] == nil {
                        layerColors[s.layerID] = NSColor(hex: project.document.layer(id: s.layerID)?.colorHex ?? "#000000") ?? .black
                    }
                    color = layerColors[s.layerID]!
                    if !project.isEditable(s) { color = color.withAlphaComponent(0.45) }
                }
                var tt = vt
                if let p = path.copy(using: &tt) {
                    ctx.addPath(p)
                    ctx.setStrokeColor(color.cgColor)
                    ctx.strokePath()
                }
            }
            if isSel, let t = preview, project.isEditable(s) {
                var moved = t.cg.concatenating(vt)
                if CanvasDetail.isVisible(box.applying(moved), in: bounds), let p = path.copy(using: &moved) {
                    ctx.addPath(p)
                    ctx.setStrokeColor(CanvasColors.selection.withAlphaComponent(0.6).cgColor)
                    ctx.strokePath()
                }
            }
        }
        ctx.restoreGState()
        // As the full path draws them: the previews of shapes on this sheet and side.
        let shownIDs = Set(shapes.map(\.id))
        for (id, shape) in nodePreview where shownIDs.contains(id) {
            stroke(ctx, CanvasPaths.cgPath(for: shape), vt, color: .systemBlue.withAlphaComponent(0.7), width: 1.5)
        }
    }

    private func drawToolpaths(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        for (i, op) in doc.project.operations.enumerated() {
            guard op.setup.isEnabled, !doc.hiddenToolpaths.contains(op.id), doc.isOnActiveSide(op), let r = doc.results[op.id],
                  !r.toolpaths.isEmpty else { continue }
            let g = toolpathGeometry(op.id, r.toolpaths, job: doc.document.job)
            let selected = doc.selectedOperationID == op.id
            let color = ToolpathColors.color(forIndex: i)
            let stale = doc.isStale(op.id)
            stroke(ctx, g.cuts, vt, color: color.withAlphaComponent(stale ? 0.35 : 0.9), width: selected ? 2.5 : 1.5)
            stroke(ctx, g.rapids, vt, color: CanvasColors.rapid.withAlphaComponent(selected ? 0.8 : 0.45), width: 1,
                   dash: [4, 4])
        }
    }

    /// Manual tab markers of the profile being edited (or the selected one); while editing, its
    /// vectors are highlighted.
    private func drawTabs(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        let editing = doc.tabEditingOperationID
        guard let id = editing ?? doc.selectedOperationID, let op = doc.operation(id), var tabs = op.profileTabs,
              tabs.isEnabled, tabs.isManual else { return }
        if editing != nil {
            for s in doc.document.shapes(ids: op.setup.shapeIDs) {
                stroke(ctx, cgPath(s), vt, color: NSColor.systemOrange.withAlphaComponent(0.8), width: 2.5)
            }
        }
        if case .tab(_, let preview?) = drag { tabs = preview }
        let r: CGFloat = editing != nil ? 6 : 4
        ctx.saveGState()
        ctx.setLineWidth(1.5)
        for p in TabEditor.positions(tabs, document: doc.document, tolerance: tolerance).compactMap({ $0 }) {
            let v = viewport.toView(p)
            let rect = CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.strokeEllipse(in: rect)
        }
        ctx.restoreGState()
    }

    private func drawOrigin(_ ctx: CGContext, _ doc: LoftLineDocument) {
        let o = viewport.toView(doc.document.job.originInMaterialFrame).cg
        let len: CGFloat = 28
        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.move(to: o); ctx.addLine(to: CGPoint(x: o.x + len, y: o.y)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.move(to: o); ctx.addLine(to: CGPoint(x: o.x, y: o.y + len)); ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1)
        let dot = CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)
        ctx.fillEllipse(in: dot); ctx.strokeEllipse(in: dot)
        ctx.restoreGState()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10)]
        ("X" as NSString).draw(at: CGPoint(x: o.x + len + 2, y: o.y - 6), withAttributes: attrs.merging([.foregroundColor: NSColor.systemRed]) { $1 })
        ("Y" as NSString).draw(at: CGPoint(x: o.x - 3, y: o.y + len + 1), withAttributes: attrs.merging([.foregroundColor: NSColor.systemGreen]) { $1 })
    }

    private func drawInteraction(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        switch drag {
        case .marquee(let a, let b, _):
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let crossing = b.x < a.x
            ctx.saveGState()
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(crossing ? 0.06 : 0.1).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            if crossing { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.stroke(r)
            ctx.restoreGState()
        case .draw(let a, let b):
            var opts = doc.drawingOptions
            opts.constrain = NSEvent.modifierFlags.contains(.shift)
            if let s = DrawingTools.shape(for: doc.activeTool, from: a, to: b, options: opts, layerID: doc.currentLayerID) {
                stroke(ctx, CanvasPaths.cgPath(for: s), vt, color: .systemBlue, width: 1.5)
            }
            drawSizeLabel(a, b, doc)
        default: break
        }
        if !clickPoints.isEmpty {
            var pts = clickPoints
            if let h = hoverDoc { pts.append(h) }
            let preview: Shape?
            if doc.activeTool == .curve {
                preview = DrawingTools.smoothCurve(points: pts, closeTolerance: 0, layerID: doc.currentLayerID)
            } else if doc.activeTool == .dimension {
                preview = nil  // drawn by drawDimensions
            } else if doc.activeTool == .arc, pts.count >= 3 {
                preview = DrawingTools.arc(points: pts, fromCenter: doc.drawingOptions.arcFromCenter, layerID: doc.currentLayerID)
            } else {
                preview = DrawingTools.polyline(points: pts, closeTolerance: 0, layerID: doc.currentLayerID)
            }
            if let s = preview { stroke(ctx, CanvasPaths.cgPath(for: s), vt, color: .systemBlue, width: 1.5) }
            for p in clickPoints {
                let v = viewport.toView(p)
                let r = CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)
                ctx.setFillColor(NSColor.systemBlue.cgColor); ctx.fill(r)
            }
        }
    }

    private func drawSizeLabel(_ a: Vec2, _ b: Vec2, _ doc: LoftLineDocument) {
        let tool = doc.activeTool
        let text: String
        if [.circle, .polygon, .star].contains(tool) {
            text = "R " + RulerTicks.label(a.distance(to: b)) + " " + doc.units.abbreviation
        } else {
            text = RulerTicks.label(abs(b.x - a.x)) + " × " + RulerTicks.label(abs(b.y - a.y)) + " " + doc.units.abbreviation
        }
        let v = viewport.toView(b)
        (text as NSString).draw(at: CGPoint(x: v.x + 10, y: v.y + 6),
                                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                 .foregroundColor: NSColor.systemBlue,
                                                 .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.8)])
    }

    // MARK: Rulers

    private func drawRulers(_ ctx: CGContext, _ doc: LoftLineDocument) {
        let rs = Self.rulerSize
        let top = CGRect(x: 0, y: bounds.height - rs, width: bounds.width, height: rs)
        let left = CGRect(x: 0, y: 0, width: rs, height: bounds.height - rs)
        NSColor.windowBackgroundColor.setFill()
        top.fill(); left.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: top.minY, width: bounds.width, height: 1).fill()
        CGRect(x: left.maxX - 1, y: 0, width: 1, height: left.height).fill()

        let major = RulerTicks.majorStep(scale: viewport.scale, units: doc.units)
        let subs = RulerTicks.subdivisions(of: major, units: doc.units)
        let minor = major / Double(subs)
        let vis = viewport.visibleRect(viewSize: Vec2(Double(bounds.width), Double(bounds.height)))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        // Horizontal ruler (X).
        ctx.saveGState(); ctx.clip(to: top.insetBy(dx: rs / 2, dy: 0).offsetBy(dx: rs / 2, dy: 0))
        for x in RulerTicks.values(from: vis.min.x, to: vis.max.x, step: minor) {
            let vx = viewport.toView(Vec2(x, 0)).x.rounded() + 0.5
            let isMajor = abs((x / major).rounded() * major - x) < minor * 0.01
            ctx.move(to: CGPoint(x: vx, y: top.minY)); ctx.addLine(to: CGPoint(x: vx, y: top.minY + (isMajor ? rs : rs * 0.3)))
            if isMajor { (RulerTicks.label(x) as NSString).draw(at: CGPoint(x: vx + 2, y: top.minY + 7), withAttributes: attrs) }
        }
        ctx.strokePath(); ctx.restoreGState()
        // Vertical ruler (Y).
        ctx.saveGState(); ctx.clip(to: left)
        for y in RulerTicks.values(from: vis.min.y, to: vis.max.y, step: minor) {
            let vy = viewport.toView(Vec2(0, y)).y.rounded() + 0.5
            let isMajor = abs((y / major).rounded() * major - y) < minor * 0.01
            ctx.move(to: CGPoint(x: left.maxX, y: vy)); ctx.addLine(to: CGPoint(x: left.maxX - (isMajor ? rs : rs * 0.3), y: vy))
            if isMajor {
                ctx.saveGState()
                ctx.translateBy(x: 6, y: vy + 2)
                ctx.rotate(by: .pi / 2)
                (RulerTicks.label(y) as NSString).draw(at: .zero, withAttributes: attrs)
                ctx.restoreGState()
            }
        }
        ctx.strokePath(); ctx.restoreGState()
        // Cursor markers.
        if let h = hoverDoc {
            let v = viewport.toView(h)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.move(to: CGPoint(x: v.x, y: top.minY)); ctx.addLine(to: CGPoint(x: v.x, y: top.maxY))
            ctx.move(to: CGPoint(x: left.minX, y: v.y)); ctx.addLine(to: CGPoint(x: left.maxX, y: v.y))
            ctx.strokePath()
        }
        ctx.restoreGState()
        // Corner with the unit abbreviation.
        let corner = CGRect(x: 0, y: top.minY, width: rs, height: rs)
        NSColor.windowBackgroundColor.setFill(); corner.fill()
        (doc.units.abbreviation as NSString).draw(at: CGPoint(x: 3, y: corner.minY + 5), withAttributes: attrs)
    }

    private func drawCursorReadout(_ doc: LoftLineDocument) {
        guard let h = hoverDoc else { return }
        let text = String(format: "X %@  Y %@ %@", RulerTicks.label((h.x * 1000).rounded() / 1000),
                          RulerTicks.label((h.y * 1000).rounded() / 1000), doc.units.abbreviation)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        let r = CGRect(x: bounds.width - size.width - 14, y: 6, width: size.width + 8, height: size.height + 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.minY + 2), withAttributes: attrs)
    }
}

extension CanvasNSView {
    /// Two-sided jobs: the hidden side's vectors, mirrored through the stock and faded.
    func drawOtherSide(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        guard doc.isTwoSided else { return }
        let project = doc.project
        let mirror = doc.document.job.otherSideTransform.cg.concatenating(vt)
        for s in project.document.shapes where project.isVisible(s) && !doc.isOnActiveSide(s) {
            stroke(ctx, cgPath(s), mirror, color: NSColor.systemGray.withAlphaComponent(0.45), width: 1, dash: [3, 3])
        }
    }
}
