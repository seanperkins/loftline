import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Per-canvas state of the drawing extras.
struct CanvasDrawingState {
    /// Characters typed while a drawing tool is active (see `QuickEntry`).
    var quickEntry = ""
    /// Guide being dragged: index of an existing guide (nil = new from a ruler).
    var guideDrag: (index: Int?, guide: GuideLine)?
    /// Last guide/alignment snap (drawn as dotted lines).
    var axisHint: AxisSnap.Result?
    /// Measure tool drag (start, current).
    var measureDrag: (Vec2, Vec2)?
    /// Freehand stroke being drawn (document points, nil when not drawing).
    var freehand: [Vec2]?
    /// Envelope corner being dragged (index into `EnvelopeEdit.offsets`).
    var envelopeCorner: Int?
    /// Interactive kerning: letter last clicked, and the letters being dragged (start, current).
    var kerningLetter: Int?
    var kerningDrag: (letters: Set<Int>, start: Vec2, current: Vec2)?
}

/// Trim and measure tools, typed entry ("quick keys") while drawing.
extension CanvasNSView {
    /// Drags owned by the drawing extras (guides, measure). True when handled.
    func extrasMouseDragged(_ event: NSEvent) -> Bool {
        if envelopeMouseDragged(event) || kerningMouseDragged(event) { return true }
        if guideMouseDragged(event) { return true }
        if var pts = drawingState.freehand {
            let p = viewport.toDocument(viewPoint(event))
            if let last = pts.last, viewport.toView(last).distance(to: viewport.toView(p)) >= 1.5 { pts.append(p) }
            drawingState.freehand = pts
            hoverDoc = p
            needsDisplay = true
            return true
        }
        if let (a, _) = drawingState.measureDrag {
            updateHover(event)
            let b = docPoint(event)
            drawingState.measureDrag = (a, b)
            document?.measurement = Measurement.between(a, b)
            needsDisplay = true
            return true
        }
        return false
    }

    func extrasMouseUp(_ event: NSEvent) -> Bool {
        if drawingState.envelopeCorner != nil { drawingState.envelopeCorner = nil; needsDisplay = true; return true }
        if kerningMouseUp(event) { return true }
        if guideMouseUp(event) { return true }
        if let pts = drawingState.freehand, let doc = document {
            drawingState.freehand = nil
            if let s = DrawingTools.freehand(points: pts, tolerance: viewport.documentLength(1.5),
                                             closeTolerance: viewport.documentLength(8), layerID: doc.currentLayerID) {
                doc.addShape(s, actionName: "Draw Freehand")
            }
            needsDisplay = true
            return true
        }
        guard let (a, b) = drawingState.measureDrag, let doc = document else { return false }
        drawingState.measureDrag = nil
        if viewport.toView(a).distance(to: viewport.toView(b)) < dragThreshold {
            // A click: measure the vector under the pointer.
            let p = docPoint(event, snapped: false)
            let visible = flatShapes(doc.project.document.shapes.filter { doc.project.isVisible($0) })
            if let id = HitTesting.pick(at: p, in: visible, tolerance: pickTolerance), let s = doc.document.shape(id: id) {
                doc.measurement = Measurement.vector(s, at: p, tolerance: tolerance)
            } else {
                doc.measurement = nil
            }
        } else {
            doc.measurement = Measurement.between(a, b)
        }
        needsDisplay = true
        return true
    }

    /// Freehand stroke in progress.
    func drawFreehand(_ ctx: CGContext) {
        guard let pts = drawingState.freehand, let f = pts.first else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.beginPath()
        let v0 = viewport.toView(f)
        ctx.move(to: CGPoint(x: v0.x, y: v0.y))
        for p in pts.dropFirst() { let v = viewport.toView(p); ctx.addLine(to: CGPoint(x: v.x, y: v.y)) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Measure line and readout.
    func drawMeasurement(_ ctx: CGContext, _ doc: LoftLineDocument) {
        guard doc.activeTool == .measure, let m = doc.measurement else { return }
        if let a = m.from, let b = m.to {
            let va = viewport.toView(a), vb = viewport.toView(b)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(1.5)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: va.x, y: va.y)); ctx.addLine(to: CGPoint(x: vb.x, y: vb.y))
            ctx.strokePath()
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            for v in [va, vb] { ctx.fillEllipse(in: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)) }
            ctx.restoreGState()
        }
        if let c = m.center, let r = m.radius {
            let vc = viewport.toView(c), vr = r * viewport.scale
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokeEllipse(in: CGRect(x: vc.x - vr, y: vc.y - vr, width: 2 * vr, height: 2 * vr))
            ctx.restoreGState()
        }
        let text = m.lines(units: doc.units).joined(separator: "\n") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attrs)
        let anchor = m.to.map { viewport.toView($0) } ?? hoverDoc.map { viewport.toView($0) } ?? Vec2(60, 60)
        let r = CGRect(x: anchor.x + 12, y: anchor.y + 8, width: size.width + 10, height: size.height + 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: r.minX + 5, y: r.minY + 3), withAttributes: attrs)
    }

    /// Trim tool click: deletes the clicked span between intersections.
    func trimClick(_ p: Vec2, _ doc: LoftLineDocument) {
        let tol = pickTolerance
        var hit = false
        doc.perform("Trim") { hit = VectorCommands.trim(at: p, pickTolerance: tol, in: &$0) }
        if !hit { NSSound.beep() }
    }

    /// True when the drawing extras consumed the key.
    func handleDrawingToolKey(_ event: NSEvent, _ doc: LoftLineDocument) -> Bool {
        let tool = doc.activeTool
        guard tool.isDragShape || tool == .polyline || tool == .curve || tool == .arc else {
            drawingState.quickEntry = ""
            return false
        }
        let buffer = drawingState.quickEntry
        switch event.keyCode {
        case 36, 76:  // return, enter
            guard !buffer.isEmpty else { return false }
            applyQuickEntry(doc)
            return true
        case 51, 117:  // delete
            guard !buffer.isEmpty else { return false }
            drawingState.quickEntry.removeLast()
            return true
        case 53:  // escape
            guard !buffer.isEmpty else { return false }
            drawingState.quickEntry = ""
            return true
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.characters, chars.count == 1, let c = chars.first,
                  QuickEntry.accepts(c, buffer: buffer) else { return false }
            drawingState.quickEntry.append(c)
            return true
        }
    }

    private func applyQuickEntry(_ doc: LoftLineDocument) {
        defer { drawingState.quickEntry = "" }
        guard let entry = QuickEntry.parse(drawingState.quickEntry) else { NSSound.beep(); return }
        let tool = doc.activeTool
        if tool.isDragShape {
            var anchor = hoverDoc ?? doc.document.job.materialBounds.center
            var direction = Vec2(1, 1)
            if case .draw(let s, let c) = drag {
                anchor = s
                direction = Vec2(c.x < s.x ? -1 : 1, c.y < s.y ? -1 : 1)
                drag = .none
            }
            guard let s = entry.shape(for: tool, anchor: anchor, direction: direction, options: doc.drawingOptions,
                                      layerID: doc.currentLayerID) else { NSSound.beep(); return }
            doc.addShape(s, actionName: "Draw \(tool.title)")
            return
        }
        // Click-built tools: the entry places the next point.
        let first = clickPoints.isEmpty
        guard let p = first ? entry.nextPoint(after: nil, cursor: hoverDoc) : entry.nextPoint(after: clickPoints.last, cursor: hoverDoc)
        else { NSSound.beep(); return }
        clickPoints.append(p)
        if tool == .arc, clickPoints.count >= 3 { finishClickShape() }
    }

    /// Typed entry shown next to the cursor.
    func drawQuickEntry(_ doc: LoftLineDocument) {
        let text = drawingState.quickEntry
        guard !text.isEmpty else { return }
        let anchor = hoverDoc.map { viewport.toView($0) } ?? Vec2(bounds.midX, bounds.midY)
        let hint: String
        switch QuickEntry.parse(text) {
        case .none: hint = ""
        case .some(.polar): hint = "  length<angle"
        case .some(.pair): hint = doc.activeTool.isDragShape ? "  W,H" : (clickPoints.isEmpty ? "  X,Y" : "  ΔX,ΔY")
        case .some(.one): hint = doc.activeTool.isDragShape ? "  size" : "  length"
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let s = (text + hint + "  ↩") as NSString
        let size = s.size(withAttributes: attrs)
        let r = CGRect(x: anchor.x + 14, y: anchor.y - size.height - 14, width: size.width + 10, height: size.height + 4)
        NSColor.systemBlue.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        s.draw(at: CGPoint(x: r.minX + 5, y: r.minY + 2), withAttributes: attrs)
    }
}
