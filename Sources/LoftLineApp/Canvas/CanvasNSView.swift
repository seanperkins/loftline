import AppKit
import CADCore
import CAMCore
import LoftLineKit

/// The 2D design canvas: material, grid, rulers, shapes, toolpath overlay, selection, drawing
/// tools. Unflipped (Y up) so document and view axes agree.
final class CanvasNSView: NSView, NSUserInterfaceValidations {
    weak var document: LoftLineDocument? {
        didSet {
            if document !== oldValue {
                didInitialFit = false; userAdjustedView = false
                flatCache.removeAll(); pathCache.removeAll()
            }
        }
    }

    var viewport = CanvasViewport() {
        didSet { if !isAutoFitting { userAdjustedView = true } }
    }
    /// Until the user pans/zooms, the view keeps the material fitted as the window resizes.
    private var userAdjustedView = false
    private var isAutoFitting = false
    static let rulerSize: CGFloat = 20

    // Interaction state.
    enum DragState {
        case none
        case pending(startView: Vec2, hitID: UUID?, extend: Bool)
        case marquee(startView: Vec2, currentView: Vec2, extend: Bool)
        case move(startDoc: Vec2, currentDoc: Vec2)
        case pan(lastView: Vec2)
        case draw(startDoc: Vec2, currentDoc: Vec2)
        /// Dragging a scale/rotate handle of the selection box.
        case handle(TransformHandle, box: Rect2, startDoc: Vec2, currentDoc: Vec2)
        /// Node tool: moving the selected nodes (`anchor` is the grabbed node's position).
        case nodes(anchor: Vec2, startDoc: Vec2, currentDoc: Vec2)
        /// Node tool: dragging one Bézier handle.
        case bezierHandle(NodeRef, PathNodes.Handle, currentDoc: Vec2)
        /// Node tool: rubber-band node selection.
        case nodeMarquee(startView: Vec2, currentView: Vec2, extend: Bool)
        /// Pen tool: dragging out the handle of the node just placed.
        case penDrag
        /// Dragging manual tab `index`; `preview` holds the moved tabs until mouse-up.
        case tab(index: Int, preview: TabSettings?)
    }
    var drag: DragState = .none
    /// Points clicked so far for the click-built tools (polyline, curve, arc, dimension).
    var clickPoints: [Vec2] = []
    /// The tool `clickPoints` and `pen` belong to; they are cleared when the tool changes, not on
    /// every document update (a mouse move publishes the cursor position).
    var transientStateTool: CanvasTool?
    /// Nodes placed so far with the Bézier pen.
    var pen = PenPath()
    /// Last object/grid snap (drawn as a marker).
    var lastSnap: SnapEngine.Result?
    /// Snap targets, rebuilt when the design or the excluded shapes change.
    var snapCache: (revision: Int, excluded: Set<UUID>, engine: SnapEngine)?
    var hoverDoc: Vec2?
    /// Space held: drags pan. Cleared when the window stops being key, since the key-up then goes to another app
    /// (Cmd-Tab with Space down would otherwise leave the canvas only panning).
    var spaceHeld = false
    private var resignKeyObserver: NSObjectProtocol?
    /// Drawing-tool extras (typed entry, measure, guides) — see CanvasDrawingTools.swift.
    var drawingState = CanvasDrawingState()
    private var didInitialFit = false
    private var lastRequestSerial = 0
    private var trackingArea: NSTrackingArea?

    // Caches keyed by shape id (entries are reused while the shape is unchanged).
    private var flatCache: [UUID: FlatShape] = [:]
    private var pathCache: [UUID: (shape: Shape, path: CGPath)] = [:]
    /// Clamp names: rebuilt only when a keep-out changes (`drawClampNames`).
    var clampCache = ClampListCache()
    private var toolpathCache: [UUID: (result: [Toolpath], job: JobSetup, cuts: CGPath, rapids: CGPath)] = [:]

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o) }
        resignKeyObserver = window.map { w in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.spaceHeld else { return }
                    self.spaceHeld = false
                    NSCursor.arrow.set()
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if (!didInitialFit || !userAdjustedView), bounds.width > 100, bounds.height > 100 {
            didInitialFit = true
            isAutoFitting = true
            fitMaterial()
            isAutoFitting = false
        }
    }

    // MARK: Requests from the document

    func handle(_ request: CanvasRequest) {
        guard request.serial != lastRequestSerial else { return }
        lastRequestSerial = request.serial
        switch request.kind {
        case .fit:
            isAutoFitting = true
            fitMaterial()
            isAutoFitting = false
            userAdjustedView = false
        case .fitSelection:
            if let doc = document, !doc.selection.isEmpty { fit(doc.project.bounds(of: doc.selection)) } else { fitMaterial() }
        case .zoomIn: zoom(by: 1.25, aboutView: center)
        case .zoomOut: zoom(by: 0.8, aboutView: center)
        }
    }

    private var center: Vec2 { Vec2(Double(bounds.midX), Double(bounds.midY)) }

    /// Area available for content (inside the rulers).
    var contentSize: Vec2 {
        Vec2(Double(bounds.width - Self.rulerSize), Double(bounds.height - Self.rulerSize))
    }

    func fitMaterial() {
        guard let doc = document else { return }
        fit(doc.document.job.materialBounds.union(doc.document.bounds))
    }

    func fit(_ rect: Rect2) {
        var vp = viewport
        vp.fit(rect, viewSize: contentSize)
        // Shift right of the vertical ruler (the horizontal ruler sits at the top).
        vp.offset += Vec2(Double(Self.rulerSize), 0)
        viewport = vp
        needsDisplay = true
    }

    func zoom(by factor: Double, aboutView p: Vec2) {
        viewport.zoom(by: factor, about: p)
        needsDisplay = true
    }

    // MARK: Caches

    var tolerance: Double { document?.units == .millimeter ? 0.02 : 0.001 }

    func flatShapes(_ shapes: [Shape]) -> [FlatShape] {
        shapes.map { s in
            if let c = flatCache[s.id], c.shape == s { return c }
            let f = FlatShape(s, tolerance: tolerance)
            flatCache[s.id] = f
            return f
        }
    }

    func cgPath(_ s: Shape) -> CGPath {
        if let c = pathCache[s.id], c.shape == s { return c.path }
        let p = CanvasPaths.cgPath(for: s)
        pathCache[s.id] = (s, p)
        return p
    }

    func toolpathGeometry(_ opID: UUID, _ tps: [Toolpath], job: JobSetup) -> (cuts: CGPath, rapids: CGPath) {
        if let c = toolpathCache[opID], c.result == tps, c.job == job { return (c.cuts, c.rapids) }
        let coords = MachineCoordinates(job: job)
        let cuts = CGMutablePath(), rapids = CGMutablePath()
        for tp in tps {
            let g = CanvasPaths.toolpathPaths(tp, coords: coords)
            cuts.addPath(g.cuts); rapids.addPath(g.rapids)
        }
        toolpathCache[opID] = (tps, job, cuts, rapids)
        return (cuts, rapids)
    }

    func pruneCaches() {
        guard let doc = document else { return }
        let ids = Set(doc.project.document.shapes.map(\.id))
        flatCache = flatCache.filter { ids.contains($0.key) }
        pathCache = pathCache.filter { ids.contains($0.key) }
        toolpathCache = toolpathCache.filter { doc.results[$0.key] != nil }
    }

    /// Shapes that can be picked (visible, unlocked layers; unlocked shapes).
    var pickableShapes: [FlatShape] {
        guard let doc = document else { return [] }
        return flatShapes(doc.project.document.shapes.filter { doc.project.isEditable($0) && doc.isOnActiveSide($0) })
    }

    // MARK: Coordinates

    func viewPoint(_ event: NSEvent) -> Vec2 { Vec2(convert(event.locationInWindow, from: nil)) }

    func docPoint(_ event: NSEvent, snapped: Bool = true, excluding: Set<UUID> = []) -> Vec2 {
        let p = viewport.toDocument(viewPoint(event))
        guard snapped, !event.modifierFlags.contains(.command) else { lastSnap = nil; drawingState.axisHint = nil; return p }
        return snap(p, excluding: excluding)
    }

    /// Snaps a document point to object points and/or the grid per the document's settings.
    func snap(_ p: Vec2, excluding: Set<UUID> = []) -> Vec2 {
        guard let doc = document else { return p }
        drawingState.axisHint = nil
        let grid = doc.snapToGrid ? doc.document.gridSpacing : 0
        guard doc.snapToObjects else {
            lastSnap = grid > 0 ? .init(point: Snapping.snap(p, grid: grid), kind: .grid) : nil
            return axisSnap(p, grid: grid, excluding: excluding) ?? lastSnap?.point ?? p
        }
        let r = snapEngine(excluding: excluding).snap(p, tolerance: snapTolerance, grid: grid)
        lastSnap = r
        if r.kind == .grid || r.kind == .none, let a = axisSnap(p, grid: grid, excluding: excluding) { return a }
        return r.point
    }

    var snapTolerance: Double { viewport.documentLength(8) }

    func snapEngine(excluding: Set<UUID>) -> SnapEngine {
        guard let doc = document else { return SnapEngine(targets: []) }
        if let c = snapCache, c.revision == doc.designRevision, c.excluded == excluding { return c.engine }
        let shapes = doc.project.document.shapes.filter { doc.project.isVisible($0) && !excluding.contains($0.id) }
        let e = SnapEngine(shapes: shapes)
        snapCache = (doc.designRevision, excluding, e)
        return e
    }

    /// Snaps a selection translation: a corner/centre of the selection box (or a node of a small
    /// selection) lands on an object point, otherwise the delta snaps to the grid.
    func snappedDelta(_ d: Vec2) -> Vec2 {
        guard let doc = document, !NSEvent.modifierFlags.contains(.command) else { return d }
        let grid = doc.snapToGrid ? doc.document.gridSpacing : 0
        guard doc.snapToObjects else { return grid > 0 ? Snapping.snap(d, grid: grid) : d }
        let b = doc.project.bounds(of: doc.selection)
        var anchors = b.isEmpty ? [] : [b.min, b.max, Vec2(b.min.x, b.max.y), Vec2(b.max.x, b.min.y), b.center]
        let shapes = doc.selectedShapes
        if shapes.reduce(0, { $0 + $1.paths.reduce(0) { $0 + $1.segments.count } }) < 400 {
            anchors += shapes.flatMap { s in s.paths.flatMap { [$0.start] + $0.segments.map(\.end) } }
        }
        return snapEngine(excluding: doc.selection).snapDelta(d, anchors: anchors, tolerance: snapTolerance, grid: grid)
    }
}
