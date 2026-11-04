import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Interactive kerning on the canvas: click a letter of the kerned text and drag it (Shift drags
/// the rest of its line too); arrow keys nudge the last clicked letter; Return/Esc finish.
/// Clicks off the letters are ignored while the mode is on.
extension CanvasNSView {
    private func kerningLetters(_ doc: LoftLineDocument) -> [TextKerning.Letter] {
        guard let spec = doc.kerningShape?.text else { return [] }
        return (try? TextKerning.letters(for: spec)) ?? []
    }

    func kerningMouseDown(_ event: NSEvent, _ doc: LoftLineDocument) -> Bool {
        guard doc.kerningShapeID != nil else { return false }
        guard doc.kerningShape != nil else { doc.endKerning(); return false }
        let p = docPoint(event, snapped: false)
        let letters = kerningLetters(doc)
        if let hit = TextKerning.letter(at: p, in: letters, tolerance: pickTolerance) {
            drawingState.kerningLetter = hit.index
            let group = LoftLineDocument.kerningGroup(hit.index, in: letters, restOfLine: event.modifierFlags.contains(.shift))
            drawingState.kerningDrag = (group, p, p)
        }
        return true
    }

    func kerningMouseDragged(_ event: NSEvent) -> Bool {
        guard var d = drawingState.kerningDrag else { return false }
        d.current = viewport.toDocument(viewPoint(event))
        drawingState.kerningDrag = d
        needsDisplay = true
        return true
    }

    func kerningMouseUp(_ event: NSEvent) -> Bool {
        guard let d = drawingState.kerningDrag else { return false }
        drawingState.kerningDrag = nil
        if viewport.toView(d.start).distance(to: viewport.toView(d.current)) >= 1 {
            document?.kernLetters(d.letters, by: d.current - d.start)
        }
        needsDisplay = true
        return true
    }

    func kerningKeyDown(_ event: NSEvent, _ doc: LoftLineDocument) -> Bool {
        guard doc.kerningShapeID != nil else { return false }
        guard doc.kerningShape != nil else { doc.endKerning(); return false }
        let step = doc.document.gridSpacing / (event.modifierFlags.contains(.shift) ? 1 : 10)
        let nudge: Vec2
        switch event.keyCode {
        case 53, 36, 76: doc.endKerning(); drawingState.kerningLetter = nil; return true
        case 123: nudge = Vec2(-step, 0)
        case 124: nudge = Vec2(step, 0)
        case 125: nudge = Vec2(0, -step)
        case 126: nudge = Vec2(0, step)
        default: return false
        }
        guard let i = drawingState.kerningLetter else { NSSound.beep(); return true }
        doc.kernLetters([i], by: nudge)
        return true
    }

    func drawKerning(_ ctx: CGContext, _ doc: LoftLineDocument) {
        guard doc.kerningShapeID != nil, let s = doc.kerningShape, var spec = s.text else { return }
        if let d = drawingState.kerningDrag {
            spec = TextKerning.moving(spec, letters: d.letters, byDocumentDelta: d.current - d.start)
        }
        guard let letters = try? TextKerning.letters(for: spec) else { return }
        let moving = drawingState.kerningDrag?.letters ?? []
        ctx.saveGState()
        ctx.setLineWidth(1)
        for l in letters where !l.paths.isEmpty {
            let r = viewRect(l.bounds).insetBy(dx: -2, dy: -2)
            let active = moving.contains(l.index) || (moving.isEmpty && drawingState.kerningLetter == l.index)
            ctx.setStrokeColor((active ? NSColor.systemTeal : NSColor.systemTeal.withAlphaComponent(0.35)).cgColor)
            ctx.stroke(r)
            if moving.contains(l.index) {
                ctx.setStrokeColor(NSColor.systemTeal.cgColor)
                for p in l.paths {
                    let pts = p.flattened(tolerance: viewport.documentLength(1)).map { viewport.toView($0).cg }
                    guard pts.count > 1 else { continue }
                    ctx.addLines(between: pts)
                    if p.isClosed { ctx.closePath() }
                }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }
}
