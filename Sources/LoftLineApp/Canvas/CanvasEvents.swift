import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// Mouse and keyboard handling for the canvas. Node-tool and pen-tool details live in
/// CanvasNodeEvents.swift; Edit-menu actions in CanvasEditMenu.swift.
extension CanvasNSView {
    var dragThreshold: Double { 3 }
    var pickTolerance: Double { viewport.documentLength(5) }
    var handleTolerance: Double { viewport.documentLength(6) }
    var rotateHandleOffset: Double { viewport.documentLength(24) }

    /// Selection box used for transform handles (nil when nothing editable is selected).
    var transformBox: Rect2? {
        guard let doc = document, !doc.selection.isEmpty,
              doc.selectedShapes.contains(where: { doc.project.isEditable($0) }) else { return nil }
        let b = doc.project.bounds(of: doc.selection)
        return b.isEmpty ? nil : b
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let doc = document else { return }
        let v = viewPoint(event)
        let tabEditing = doc.tabEditingOperationID != nil
        if spaceHeld || event.modifierFlags.contains(.option) && doc.activeTool == .select && !tabEditing {
            drag = .pan(lastView: v); NSCursor.closedHand.set(); return
        }
        if envelopeMouseDown(event, doc) || kerningMouseDown(event, doc) { needsDisplay = true; return }
        if !tabEditing, guideMouseDown(event, doc) { needsDisplay = true; return }
        if tabEditing {
            tabMouseDown(event, doc)
            needsDisplay = true
            return
        }
        switch doc.activeTool {
        case .select:
            let p = docPoint(event, snapped: false)
            if let box = transformBox,
               let h = TransformHandles.hit(p, box: box, rotateOffset: rotateHandleOffset, tolerance: handleTolerance) {
                drag = .handle(h, box: box, startDoc: p, currentDoc: p)
                return
            }
            let hit = HitTesting.pick(at: p, in: pickableShapes, tolerance: pickTolerance)
            drag = .pending(startView: v, hitID: hit, extend: event.modifierFlags.contains(.shift))
        case .nodeEdit:
            nodeMouseDown(event)
        case .pen:
            penMouseDown(event)
        case .polyline, .curve:
            let p = docPoint(event)
            if event.clickCount >= 2 { finishClickShape(); return }
            if clickPoints.count >= 2, let first = clickPoints.first,
               viewport.toView(first).distance(to: v) < 8 {
                clickPoints.append(first); finishClickShape(); return
            }
            clickPoints.append(p)
        case .trim:
            trimClick(docPoint(event, snapped: false), doc)
        case .measure:
            let p = docPoint(event)
            drawingState.measureDrag = (p, p)
        case .freehand:
            drawingState.freehand = [docPoint(event)]
        case .dimension:
            dimensionClick(event, doc)
        case .arc:
            clickPoints.append(docPoint(event))
            if clickPoints.count >= 3 { finishClickShape() }
        case .text:
            placeText(at: docPoint(event))
        default:
            let p = docPoint(event)
            drag = .draw(startDoc: p, currentDoc: p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let doc = document else { return }
        if extrasMouseDragged(event) { return }
        let v = viewPoint(event)
        updateHover(event)
        switch drag {
        case .pan(let last):
            viewport.pan(by: v - last)
            drag = .pan(lastView: v)
        case .pending(let start, let hit, let extend):
            guard start.distance(to: v) >= dragThreshold else { return }
            if let id = hit {
                if !doc.selection.contains(id) { doc.select(id, extending: extend) }
                let startDoc = viewport.toDocument(start)
                drag = .move(startDoc: startDoc, currentDoc: viewport.toDocument(v))
            } else {
                drag = .marquee(startView: start, currentView: v, extend: extend)
            }
        case .move(let s, _):
            drag = .move(startDoc: s, currentDoc: viewport.toDocument(v))
        case .marquee(let s, _, let extend):
            drag = .marquee(startView: s, currentView: v, extend: extend)
        case .draw(let s, _):
            drag = .draw(startDoc: s, currentDoc: docPoint(event))
        case .handle(let h, let box, let s, _):
            let raw = viewport.toDocument(v)
            // Scale handles snap the grabbed point; rotation uses the raw angle.
            let cur = h == .rotate || event.modifierFlags.contains(.command) ? raw : snap(raw, excluding: doc.selection)
            drag = .handle(h, box: box, startDoc: s, currentDoc: cur)
        case .nodes, .bezierHandle, .nodeMarquee, .penDrag:
            nodeMouseDragged(event)
        case .tab(let i, _):
            if let (op, tabs) = editedProfileTabs(doc) {
                let moved = TabEditor.moving(i, to: docPoint(event, snapped: false), in: tabs,
                                             shapes: doc.document.shapes(ids: op.setup.shapeIDs), tolerance: tolerance)
                drag = .tab(index: i, preview: moved)
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    // MARK: Tab editor

    /// The Profile operation under tab editing and its tab settings.
    private func editedProfileTabs(_ doc: LoftLineDocument) -> (AnyOperation, TabSettings)? {
        guard let id = doc.tabEditingOperationID, let op = doc.operation(id), let tabs = op.profileTabs else { return nil }
        return (op, tabs)
    }

    /// Click on a tab: start dragging it (option-click deletes it). Click on one of the
    /// toolpath's vectors: add a tab there.
    private func tabMouseDown(_ event: NSEvent, _ doc: LoftLineDocument) {
        guard let (op, tabs) = editedProfileTabs(doc) else { doc.tabEditingOperationID = nil; return }
        let p = docPoint(event, snapped: false)
        if let i = TabEditor.hit(at: p, tabs: tabs, document: doc.document, radius: viewport.documentLength(7),
                                 tolerance: tolerance) {
            if event.modifierFlags.contains(.option) {
                doc.setProfileTabs(TabEditor.removing(i, from: tabs), for: op.id, actionName: "Delete Tab")
            } else {
                drag = .tab(index: i, preview: nil)
            }
            return
        }
        let base = tabs.isManual ? tabs : TabEditor.makeManual(tabs, shapes: [])
        if let t = TabEditor.adding(at: p, to: base, shapes: doc.document.shapes(ids: op.setup.shapeIDs),
                                    maxDistance: viewport.documentLength(8), tolerance: tolerance) {
            doc.setProfileTabs(t, for: op.id, actionName: "Add Tab")
        } else {
            NSSound.beep()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let doc = document else { drag = .none; return }
        if extrasMouseUp(event) { drag = .none; return }
        switch drag {
        case .pending(_, let hit, let extend):
            if let id = hit { doc.select(id, extending: extend) } else if !extend { doc.clearSelection() }
        case .move(let s, let c):
            doc.translateSelection(by: snappedDelta(c - s))
        case .marquee(let a, let b, let extend):
            let rect = Rect2(points: [viewport.toDocument(a), viewport.toDocument(b)])
            let ids = HitTesting.select(in: rect, candidates: pickableShapes, crossing: b.x < a.x)
            if extend { doc.addToSelection(ids) } else { doc.setSelection(doc.document.expandToGroups(ids)) }
        case .draw(let a, let b):
            var opts = doc.drawingOptions
            opts.constrain = event.modifierFlags.contains(.shift)
            if let s = DrawingTools.shape(for: doc.activeTool, from: a, to: b, options: opts, layerID: doc.currentLayerID) {
                doc.addShape(s, actionName: "Draw \(doc.activeTool.title)")
            }
        case .handle(let h, let box, let s, let c):
            let t = handleTransform(h, box: box, from: s, to: c, flags: event.modifierFlags)
            if t != .identity { doc.transformSelection(by: t, actionName: h == .rotate ? "Rotate" : "Scale") }
        case .nodes, .bezierHandle, .nodeMarquee, .penDrag:
            nodeMouseUp(event)
        case .pan:
            NSCursor.arrow.set()
        case .tab(_, let preview):
            if let t = preview, let id = doc.tabEditingOperationID { doc.setProfileTabs(t, for: id, actionName: "Move Tab") }
        case .none:
            break
        }
        drag = .none
        needsDisplay = true
    }

    /// Transform for a handle drag: Shift keeps proportions (or snaps rotation to 15°),
    /// Option scales about the centre.
    func handleTransform(_ h: TransformHandle, box: Rect2, from s: Vec2, to c: Vec2, flags: NSEvent.ModifierFlags) -> Transform2D {
        TransformHandles.transform(dragging: h, box: box, from: s, to: c, keepAspect: flags.contains(.shift),
                                   fromCenter: flags.contains(.option), angleSnap: flags.contains(.shift) ? 15 : 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let doc = document else { return }
        let p = docPoint(event, snapped: false)
        if doc.activeTool == .nodeEdit, let r = nodeHit(at: p) {
            if !doc.nodeSelection.contains(r) { doc.nodeSelection = [r] }
        } else if let hit = HitTesting.pick(at: p, in: pickableShapes, tolerance: pickTolerance), !doc.selection.contains(hit) {
            doc.select(hit, extending: false)
        }
        NSMenu.popUpContextMenu(contextMenu(doc), with: event, for: self)
    }

    override func otherMouseDown(with event: NSEvent) { drag = .pan(lastView: viewPoint(event)) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { drag = .none }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverDoc = nil
        lastSnap = nil
        document?.cursorPosition = nil
        needsDisplay = true
    }

    func updateHover(_ event: NSEvent) {
        let drawing = document?.activeTool.isClickBuilt == true || (document?.activeTool.isDragShape ?? false)
            || document?.activeTool == .text || document?.activeTool == .measure
        let p = docPoint(event, snapped: drawing)
        if !drawing { lastSnap = nil }
        hoverDoc = p
        document?.cursorPosition = p
    }

    override func scrollWheel(with event: NSEvent) {
        let v = viewPoint(event)
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(Double(dy)), aboutView: v)
        } else {
            viewport.pan(by: Vec2(Double(event.scrollingDeltaX), Double(-event.scrollingDeltaY)))
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + Double(event.magnification), aboutView: viewPoint(event))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let doc = document else { return super.keyDown(with: event) }
        if kerningKeyDown(event, doc) || handleDrawingToolKey(event, doc) { needsDisplay = true; return }
        let step = doc.document.gridSpacing * (event.modifierFlags.contains(.shift) ? 10 : 1)
        let nodeMode = doc.activeTool == .nodeEdit && !doc.nodeSelection.isEmpty
        func nudge(_ d: Vec2) {
            // The envelope's box is fixed when the edit starts, so a nudge would make Apply bend other than the preview.
            guard doc.envelopeEdit == nil else { NSSound.beep(); return }
            if nodeMode { doc.moveSelectedNodes(by: d) } else { doc.translateSelection(by: d, actionName: "Nudge") }
        }
        switch event.keyCode {
        case 48: // tab: keyboard selection of vectors (Control-Tab leaves the canvas)
            if !handleTabKey(event) { return super.keyDown(with: event) }
        case 49: // space
            spaceHeld = true; NSCursor.openHand.set()
        case 51, 117: // delete, forward delete
            if doc.activeTool == .pen, !pen.isEmpty { pen.removeLast() }
            else if doc.activeTool.isClickBuilt, !clickPoints.isEmpty { clickPoints.removeLast() }
            else if nodeMode { doc.deleteSelectedNodes() }
            else { doc.deleteSelection() }
        case 53: // escape
            if doc.envelopeEdit != nil { doc.cancelEnvelopeEdit() }
            else if doc.tabEditingOperationID != nil { doc.tabEditingOperationID = nil } else { cancelOrStepBack(doc) }
        case 36, 76: // return, enter
            if doc.envelopeEdit != nil { doc.applyEnvelopeEdit() } else { finishClickShape() }
        case 123: nudge(Vec2(-step, 0))
        case 124: nudge(Vec2(step, 0))
        case 125: nudge(Vec2(0, -step))
        case 126: nudge(Vec2(0, step))
        default:
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard plain, let ch = event.charactersIgnoringModifiers?.lowercased().first else { return super.keyDown(with: event) }
            if ch == "f" { fitMaterial() } else if let tool = CanvasTool.forShortcut(ch) { doc.activeTool = tool } else {
                super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }

    private func cancelOrStepBack(_ doc: LoftLineDocument) {
        if !clickPoints.isEmpty || !pen.isEmpty {
            clickPoints = []; pen = PenPath()
        } else if doc.activeTool == .nodeEdit, !doc.nodeSelection.isEmpty {
            doc.nodeSelection = []
        } else if doc.activeTool != .select {
            doc.activeTool = .select
        } else {
            doc.clearSelection()
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; NSCursor.arrow.set() } else { super.keyUp(with: event) }
    }

    // MARK: Click-built shapes

    func finishClickShape(closed: Bool = false) {
        guard let doc = document else { return }
        defer { clickPoints = []; pen = PenPath(); needsDisplay = true }
        let tol = viewport.documentLength(8)
        let shape: Shape?
        switch doc.activeTool {
        case .pen:
            shape = pen.path(closed: closed).map { Shape(name: "Curve", layerID: doc.currentLayerID, paths: [$0]) }
        case .curve:
            shape = DrawingTools.smoothCurve(points: clickPoints, closeTolerance: tol, layerID: doc.currentLayerID)
        case .arc:
            shape = DrawingTools.arc(points: clickPoints, fromCenter: doc.drawingOptions.arcFromCenter, layerID: doc.currentLayerID)
        case .dimension:
            shape = nil
        default:
            shape = DrawingTools.polyline(points: clickPoints, closeTolerance: tol, layerID: doc.currentLayerID)
        }
        if let s = shape { doc.addShape(s, actionName: "Draw \(doc.activeTool.title)") }
    }

    private func placeText(at p: Vec2) {
        guard let doc = document else { return }
        let o = doc.drawingOptions
        guard !o.text.isEmpty else { return }
        do {
            let spec = TextSpec(string: o.text, fontName: o.fontName, size: o.fontSize, alignment: o.textAlignment,
                                lineSpacing: o.lineSpacing, letterSpacing: o.letterSpacing, anchor: p)
            let s = try TextOutliner().shape(for: spec, layerID: doc.currentLayerID)
            guard !s.paths.isEmpty else { return }
            doc.addShape(s, actionName: "Add Text")
        } catch {
            doc.report(AlertMessage(title: "Text", message: ImportService.describe(error)))
        }
    }
}
