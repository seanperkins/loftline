import CADCore
import CAMCore
import Foundation

/// Sheets opened by the drawing tools (one `DocumentSheet.drawing` case keeps the shared enum
/// change small).
public enum DrawingSheet: String, Identifiable {
    case dogbone, arrayLinear, validator, mirror, trimBoundary, filletChamfer, arrayCircular, curveFit, textFit, textOnCurve, traceBitmap, distort, offsetOpen, inlayOffset, copyAlong, vectorTexture, boundary, plaque, joinVectors
    public var id: String { rawValue }
}

/// Drawing-area commands on the selection. Each mutates `project` in place and returns the new
/// selection (or nil when nothing changed).
public enum VectorCommands {
    /// Geometry tolerance for the document's units.
    public static func tolerance(_ units: LengthUnit) -> Double { units == .inch ? 0.0005 : 0.01 }

    /// Replaces a shape's paths in place: parametric/text provenance is dropped.
    public static func replacePaths(_ id: UUID, with paths: [Path], operation: String, in project: inout LoftLineProject) {
        guard let i = project.document.shapes.firstIndex(where: { $0.id == id }) else { return }
        var s = project.document.shapes[i]
        guard s.paths != paths else { return }
        s.paths = paths
        s.origin = .derived(operation: operation)
        s.text = nil
        project.document.shapes[i] = s
    }

    // MARK: Text

    /// Re-outlines a live text shape from `spec` (same transform → same anchor).
    public static func updateText(_ id: UUID, spec: TextSpec, in project: inout LoftLineProject) throws {
        guard let i = project.document.shapes.firstIndex(where: { $0.id == id }),
              project.isEditable(project.document.shapes[i]) else { return }
        let rebuilt = try TextOutliner().shape(for: spec, layerID: project.document.shapes[i].layerID)
        var s = project.document.shapes[i]
        s.paths = rebuilt.paths
        s.origin = rebuilt.origin
        s.text = spec
        if s.name.isEmpty || s.name == project.document.shapes[i].text?.string.replacingOccurrences(of: "\n", with: " ") {
            s.name = rebuilt.name
        }
        project.document.shapes[i] = s
    }

    /// Scales and centres the text shapes among `ids` to fill the bounding box of the first
    /// other selected shape (or the material when there is none), inset by `margin`.
    /// `stretch` fills both directions; otherwise proportions are kept. Returns false if nothing fitted.
    @discardableResult
    public static func fitTextToBox(_ ids: [UUID], margin: Double, stretch: Bool, in project: inout LoftLineProject) -> Bool {
        let shapes = project.document.shapes(ids: ids)
        let texts = shapes.filter { $0.text != nil && project.isEditable($0) }
        guard !texts.isEmpty else { return false }
        let textIDs = Set(project.document.expandToGroups(texts.map(\.id)))
        let boundary = shapes.first { !textIDs.contains($0.id) }
        let box = (boundary?.bounds() ?? project.document.job.materialBounds).insetBy(margin)
        let b = project.bounds(of: textIDs)
        guard box.width > 0, box.height > 0, b.width > 1e-12, b.height > 1e-12 else { return false }
        var sx = box.width / b.width, sy = box.height / b.height
        if !stretch { sx = min(sx, sy); sy = sx }
        let t = Transform2D.scale(sx, sy, about: b.center).concatenating(.translation(box.center - b.center))
        project.transformShapes(textIDs, by: t)
        return true
    }

    /// Circle used to bend text into an arc: text centred on top (convex) or along the bottom
    /// (concave), reading left to right either way.
    public static func bendCircle(baselineCenter c: Vec2, radius r: Double, convex: Bool) -> Path {
        let center = convex ? c - Vec2(0, r) : c + Vec2(0, r)
        let start = convex ? center - Vec2(0, r) : center + Vec2(0, r)
        let mid = convex ? center + Vec2(0, r) : center - Vec2(0, r)
        return Path(start: start, segments: [.arc(to: mid, center: center, clockwise: convex),
                                             .arc(to: start, center: center, clockwise: convex)], isClosed: true)
    }

    /// Text along a curve: the live text `textID` laid along `curveID` (or, with no curve, bent
    /// into an arc of `bendRadius`). Adds a plain-vector shape and returns its ID; the original
    /// text is deleted unless `keepOriginal`.
    public static func textOnCurve(textID: UUID, curveID: UUID?, bendRadius: Double, convex: Bool,
                            placement: TextOnPath.Placement, offset: Double, flip: Bool, keepOriginal: Bool,
                            in project: inout LoftLineProject) throws -> UUID? {
        guard let s = project.document.shape(id: textID), let spec = s.text else { return nil }
        let glyphs = try TextOutliner().glyphs(for: spec.string, fontName: spec.fontName, size: spec.displayedSize,
                                               letterSpacing: spec.letterSpacing * spec.scale)
        let guide: Path
        if let cid = curveID, let curve = project.document.shape(id: cid), let p = curve.paths.first {
            guide = p
        } else {
            guard bendRadius > 0 else { return nil }
            let b = s.bounds()
            guide = bendCircle(baselineCenter: Vec2(b.center.x, b.min.y), radius: bendRadius, convex: convex)
        }
        let paths = TextOnPath.layout(glyphs, along: guide, placement: curveID == nil ? .center : placement,
                                      offset: offset, flip: flip, tolerance: tolerance(project.document.units) / 4)
        guard !paths.isEmpty else { return nil }
        let n = Shape(name: spec.string.replacingOccurrences(of: "\n", with: " "), layerID: s.layerID, paths: paths,
                      origin: .derived(operation: "text on curve"))
        project.document.add(n)
        if !keepOriginal { project.deleteShapes([textID]) }
        return n.id
    }

    /// Turns live text into plain vectors (no further text editing).
    public static func convertTextToCurves(_ ids: Set<UUID>, in project: inout LoftLineProject) {
        for i in project.document.shapes.indices where ids.contains(project.document.shapes[i].id) {
            guard project.document.shapes[i].text != nil else { continue }
            project.document.shapes[i].text = nil
            project.document.shapes[i].origin = .derived(operation: "text to curves")
        }
    }

    /// Editable (unlocked, on an editable layer) shapes among `ids`, in order.
    public static func editableShapes(_ ids: [UUID], in project: LoftLineProject) -> [Shape] {
        project.document.shapes(ids: ids).filter(project.isEditable)
    }

    // MARK: Dog-bones

    /// Adds corner relief to the closed paths of the selection. Returns the number of corners.
    @discardableResult
    public static func dogbone(_ ids: [UUID], toolDiameter: Double, style: Dogbone.Style, side: Dogbone.CutSide,
                        maxAngle: Double, in project: inout LoftLineProject) -> Int {
        guard toolDiameter > 0 else { return 0 }
        var count = 0
        for s in editableShapes(ids, in: project) where s.paths.contains(where: \.isClosed) {
            let n = Dogbone.reliefCount(s.paths, radius: toolDiameter / 2, style: style, side: side, maxAngle: maxAngle)
            guard n > 0 else { continue }
            count += n
            let paths = Dogbone.apply(to: s.paths, radius: toolDiameter / 2, style: style, side: side, maxAngle: maxAngle)
            replacePaths(s.id, with: paths, operation: "dog-bone", in: &project)
        }
        return count
    }

    // MARK: Validator

    /// Shapes the validator looks at: the selection, or every visible shape when nothing is selected.
    public static func validationScope(_ ids: [UUID], in project: LoftLineProject) -> [Shape] {
        ids.isEmpty ? project.document.shapes.filter(project.isVisible) : project.document.shapes(ids: ids)
    }

    /// Applies the validator's automatic repairs. Returns the number of issues repaired.
    @discardableResult
    public static func repair(_ issues: [VectorIssue], in project: inout LoftLineProject) -> Int {
        let fixable = issues.filter(\.kind.isFixable)
        let ids = Set(fixable.map(\.shapeID))
        let shapes = project.document.shapes.filter { ids.contains($0.id) && project.isEditable($0) }
        let editable = Set(shapes.map(\.id))
        let used = fixable.filter { editable.contains($0.shapeID) }
        let tol = tolerance(project.document.units)
        let fixed = VectorValidator.fix(shapes, issues: used, tolerance: tol)
        let kept = Set(fixed.map(\.id))
        project.deleteShapes(editable.subtracting(kept))
        for s in fixed { project.document.replace(s) }
        return used.count
    }

    // MARK: Trace bitmap

    /// Scales traced pixel outlines to `width` document units, centred on `center`.
    public static func placeTrace(_ paths: [Path], imageSize: Vec2, width: Double, center: Vec2) -> [Path] {
        guard imageSize.x > 0, width > 0 else { return [] }
        let s = width / imageSize.x
        let t = Transform2D.scale(s, s).concatenating(.translation(center - imageSize * (s / 2)))
        return paths.map { $0.transformed(t) }
    }

    /// Adds the traced outlines as one shape on `layer`. Returns its ID.
    public static func addTrace(_ paths: [Path], name: String, layer: UUID, in project: inout LoftLineProject) -> UUID? {
        guard !paths.isEmpty else { return nil }
        let s = Shape(name: name, layerID: layer, paths: paths, origin: .derived(operation: "trace bitmap"))
        project.document.add(s)
        return s.id
    }

    // MARK: Curve fitting

    /// Refits the selected vectors with lines and arcs. Returns (segments before, after).
    @discardableResult
    public static func fitCurves(_ ids: [UUID], tolerance: Double, in project: inout LoftLineProject) -> (Int, Int) {
        var before = 0, after = 0
        for s in editableShapes(ids, in: project) {
            let paths = s.paths.map { CurveFit.fit($0, tolerance: tolerance) }
            let old = CurveFit.segmentCount(s.paths), new = CurveFit.segmentCount(paths)
            before += old
            // Only replace when it actually simplifies (keeps clean Béziers/arcs as they are).
            if new < old {
                replacePaths(s.id, with: paths, operation: "fit curves", in: &project)
                after += new
            } else {
                after += old
            }
        }
        return (before, after)
    }

    // MARK: Fillet / chamfer

    /// Rounds or bevels corners: the selected nodes when `nodes` is not empty (node-edit form),
    /// otherwise every line–line corner of the selected shapes. Returns the shapes changed.
    @discardableResult
    public static func treatCorners(_ kind: CornerOps.Kind, shapes ids: [UUID], nodes: Set<NodeRef>,
                             in project: inout LoftLineProject) -> Int {
        var changed = 0
        if !nodes.isEmpty {
            for id in Set(nodes.map(\.shapeID)) {
                guard let s = project.document.shape(id: id), project.isEditable(s) else { continue }
                let e = ShapeNodes.editable(s)
                var paths = e.paths
                for (i, p) in paths.enumerated() {
                    let corners = Set(nodes.filter { $0.shapeID == id && $0.path == i }.map(\.node))
                    if !corners.isEmpty { paths[i] = CornerOps.apply(kind, to: p, corners: corners) }
                }
                if paths != e.paths { replacePaths(id, with: paths, operation: "corner", in: &project); changed += 1 }
            }
            return changed
        }
        for s in editableShapes(ids, in: project) {
            let paths = s.paths.map { CornerOps.apply(kind, to: $0) }
            if paths != s.paths { replacePaths(s.id, with: paths, operation: "corner", in: &project); changed += 1 }
        }
        return changed
    }

    // MARK: Trim

    /// Replaces one path of a shape with `pieces`; the shape is deleted when nothing is left.
    public static func replacePath(_ id: UUID, index: Int, with pieces: [Path], operation: String, in project: inout LoftLineProject) {
        guard let s = project.document.shape(id: id), s.paths.indices.contains(index) else { return }
        var paths = s.paths
        paths.remove(at: index)
        paths.insert(contentsOf: pieces, at: index)
        if paths.isEmpty { project.deleteShapes([id]) } else { replacePaths(id, with: paths, operation: operation, in: &project) }
    }

    /// Interactive trim: deletes the span of the vector under `point` between its neighbouring
    /// intersections with every other visible vector. Returns false when nothing was hit.
    @discardableResult
    public static func trim(at point: Vec2, pickTolerance: Double, in project: inout LoftLineProject) -> Bool {
        let tol = tolerance(project.document.units)
        let candidates = project.document.shapes.filter(project.isEditable)
        var best: (id: UUID, path: Int, d: Double)?
        for s in candidates where s.bounds().insetBy(-pickTolerance).contains(point) {
            for (i, p) in s.paths.enumerated() {
                let d = PathSplitting.nearestParameter(PathSplitting.sample(p, tolerance: tol), to: point).distance
                if d <= pickTolerance, d < (best?.d ?? .infinity) { best = (s.id, i, d) }
            }
        }
        guard let hit = best, let shape = project.document.shape(id: hit.id) else { return false }
        let target = shape.paths[hit.path]
        let box = target.bounds().insetBy(-tol)
        var cutters: [Path] = []
        for s in project.document.shapes where project.isVisible(s) && s.bounds().intersects(box) {
            for (i, p) in s.paths.enumerated() where !(s.id == hit.id && i == hit.path) { cutters.append(p) }
        }
        let pieces = Trim.trimSpan(target, cutters: cutters, at: point, tolerance: tol)
        replacePath(hit.id, index: hit.path, with: pieces, operation: "trim", in: &project)
        return true
    }

    /// Trims the targets to the first selected closed shape. Targets are the other selected
    /// shapes, or every editable shape when only the boundary is selected.
    @discardableResult
    public static func trimToBoundary(_ ids: [UUID], keepInside: Bool, in project: inout LoftLineProject) -> Int {
        guard let boundary = project.document.shapes(ids: ids).first(where: { $0.paths.contains(where: \.isClosed) }) else { return 0 }
        let tol = tolerance(project.document.units)
        let others = ids.filter { $0 != boundary.id }
        let targets = (others.isEmpty ? project.document.shapes.map(\.id).filter { $0 != boundary.id } : others)
            .compactMap { project.document.shape(id: $0) }.filter(project.isEditable)
        var changed = 0
        for s in targets {
            let paths = s.paths.flatMap { Trim.toBoundary($0, boundary: boundary.paths, keepInside: keepInside, tolerance: tol) }
            guard paths != s.paths else { continue }
            changed += 1
            if paths.isEmpty { project.deleteShapes([s.id]) } else { replacePaths(s.id, with: paths, operation: "trim", in: &project) }
        }
        return changed
    }

    // MARK: Open offsets

    public enum OpenOffsetSide: String, CaseIterable, Identifiable {
        case left, right, both, outline
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .left: return "Left side"
            case .right: return "Right side"
            case .both: return "Both sides"
            case .outline: return "Closed outline around"
            }
        }
    }

    /// Offsets the open vectors of the selection, adding one new shape per source shape.
    public static func offsetOpen(_ ids: [UUID], distance: Double, side: OpenOffsetSide, in project: inout LoftLineProject) -> [UUID] {
        let tol = tolerance(project.document.units)
        let d = abs(distance)
        guard d > 0 else { return [] }
        var newIDs: [UUID] = []
        for s in project.document.shapes(ids: ids) {
            let open = s.paths.filter { !$0.isClosed }
            guard !open.isEmpty else { continue }
            var paths: [Path] = []
            switch side {
            case .left: paths = open.compactMap { OpenOffset.oneSide($0, distance: d, tolerance: tol) }
            case .right: paths = open.compactMap { OpenOffset.oneSide($0, distance: -d, tolerance: tol) }
            case .both: paths = open.flatMap { p in [d, -d].compactMap { OpenOffset.oneSide(p, distance: $0, tolerance: tol) } }
            case .outline: paths = PathOps.offsetOpen(open, by: d, tolerance: tol)
            }
            guard !paths.isEmpty else { continue }
            let n = Shape(name: (s.name.isEmpty ? "Vector" : s.name) + " offset", layerID: s.layerID, paths: paths,
                          origin: .derived(operation: "offset"))
            project.document.add(n)
            newIDs.append(n.id)
        }
        return newIDs
    }

    // MARK: Boundary

    /// Adds a closed boundary vector around the selection. Returns its ID.
    public static func boundary(_ ids: [UUID], kind: BoundaryVector.Kind, margin: Double, gap: Double,
                         in project: inout LoftLineProject) -> UUID? {
        let shapes = project.document.shapes(ids: project.document.expandToGroups(ids))
        guard let first = shapes.first else { return nil }
        let paths = BoundaryVector.make(kind, around: shapes.flatMap(\.paths), margin: margin, gap: gap,
                                        tolerance: tolerance(project.document.units))
        guard !paths.isEmpty else { return nil }
        let s = Shape(name: "Boundary", layerID: first.layerID, paths: paths, origin: .derived(operation: "boundary"))
        project.document.add(s)
        return s.id
    }

    /// Adds a plaque outline around the selection's bounds grown by `margin`. Returns its ID.
    public static func plaque(_ ids: [UUID], style: PlaqueMaker.Style, margin: Double, corner: Double, borderInset: Double,
                       in project: inout LoftLineProject) -> UUID? {
        let all = project.document.expandToGroups(ids)
        guard let first = project.document.shapes(ids: all).first else { return nil }
        var box = project.bounds(of: Set(all)).insetBy(-max(margin, 0))
        if style == .oval {
            // An ellipse through the box corners' reach: grow so the content stays inside.
            box = Rect2(min: box.center - box.size * (0.5 * 2.0.squareRoot()), max: box.center + box.size * (0.5 * 2.0.squareRoot()))
        }
        let paths = PlaqueMaker.make(style, box: box, corner: corner, borderInset: borderInset, tolerance: tolerance(project.document.units))
        guard !paths.isEmpty else { return nil }
        let s = Shape(name: "Plaque", layerID: first.layerID, paths: paths, origin: .derived(operation: "plaque"))
        project.document.add(s)
        return s.id
    }

    // MARK: Vector texture

    /// Fills the selected closed shapes (together, even-odd) with a pattern; returns the new shape.
    public static func vectorTexture(_ ids: [UUID], options: VectorTexture.Options, in project: inout LoftLineProject) -> UUID? {
        let shapes = project.document.shapes(ids: ids).filter { $0.paths.contains(where: \.isClosed) }
        guard let first = shapes.first else { return nil }
        let paths = VectorTexture.fill(shapes.flatMap(\.paths), options: options, tolerance: tolerance(project.document.units))
        guard !paths.isEmpty else { return nil }
        let s = Shape(name: "Texture", layerID: first.layerID, paths: paths, origin: .derived(operation: "vector texture"))
        project.document.add(s)
        return s.id
    }

    // MARK: Straight-wall inlay

    /// Pocket and plug outlines for a straight-wall (end mill) inlay. Both start from the design
    /// with every corner rounded to the cutter radius (what an end mill can actually cut on
    /// both parts), then the pocket grows and the plug shrinks by half the clearance. The plug
    /// is mirrored left↔right (it is glued face down) unless `mirrorPlug` is false, and placed
    /// beside the design. Returns (pocket, plug) shape IDs.
    public static func straightInlay(_ ids: [UUID], toolDiameter: Double, clearance: Double, mirrorPlug: Bool,
                              in project: inout LoftLineProject) -> (UUID, UUID)? {
        let shapes = project.document.shapes(ids: ids).filter(\.isClosed)
        guard !shapes.isEmpty, toolDiameter > 0 else { return nil }
        let tol = tolerance(project.document.units)
        let r = toolDiameter / 2
        let design = PathOps.union(shapes: shapes.map(\.paths), tolerance: tol)
        let opened = PathOps.offset(PathOps.offset(design, by: -r, tolerance: tol), by: r, tolerance: tol)
        let rounded = PathOps.offset(PathOps.offset(opened, by: r, tolerance: tol), by: -r, tolerance: tol)
        let pocket = PathOps.offset(rounded, by: max(clearance, 0) / 2, tolerance: tol)
        var plug = clearance > 0 ? PathOps.offset(rounded, by: -clearance / 2, tolerance: tol) : rounded
        guard !pocket.isEmpty, !plug.isEmpty else { return nil }
        let b = Rect2(points: plug.flatMap { $0.flattened(tolerance: tol) })
        var t = Transform2D.translation(Vec2(b.width + toolDiameter * 4, 0))
        if mirrorPlug { t = Transform2D.mirror(horizontalAxis: false, about: b.center).concatenating(t) }
        plug = plug.map { $0.transformed(t) }
        let layer = shapes[0].layerID
        let ps = Shape(name: "Inlay pocket", layerID: layer, paths: pocket, origin: .derived(operation: "inlay pocket"))
        let pl = Shape(name: "Inlay plug", layerID: layer, paths: plug, origin: .derived(operation: "inlay plug"))
        project.document.add(ps)
        project.document.add(pl)
        return (ps.id, pl.id)
    }

    // MARK: Extend

    /// Extends the open vectors of the selection to the nearest other visible vector. Returns
    /// the number of paths changed.
    @discardableResult
    public static func extendToBoundaries(_ ids: [UUID], in project: inout LoftLineProject) -> Int {
        let tol = tolerance(project.document.units)
        let m = project.document.job.materialBounds
        let reach = max(m.width, m.height) * 2
        var changed = 0
        for s in editableShapes(ids, in: project) where s.paths.contains(where: { !$0.isClosed }) {
            var paths = s.paths
            for (i, p) in s.paths.enumerated() where !p.isClosed {
                var others: [Path] = []
                for o in project.document.shapes where project.isVisible(o) {
                    for (j, q) in o.paths.enumerated() where !(o.id == s.id && j == i) { others.append(q) }
                }
                let e = Extend.toBoundaries(p, boundaries: others, maxDistance: reach, tolerance: tol)
                if e != p { paths[i] = e; changed += 1 }
            }
            if paths != s.paths { replacePaths(s.id, with: paths, operation: "extend", in: &project) }
        }
        return changed
    }

    // MARK: Shear / distort

    public static func shear(_ ids: [UUID], xDegrees: Double, yDegrees: Double, in project: inout LoftLineProject) {
        let all = Set(project.document.expandToGroups(ids))
        let b = project.bounds(of: all)
        guard !b.isEmpty, abs(xDegrees) < 89, abs(yDegrees) < 89 else { return }
        project.transformShapes(all, by: Distort.shear(xDegrees: xDegrees, yDegrees: yDegrees, about: b.center))
    }

    /// Moves the selection's bounding-box corners by `offsets` (lower-left, lower-right,
    /// upper-right, upper-left) and bends the vectors to follow.
    public static func envelope(_ ids: [UUID], offsets: [Vec2], in project: inout LoftLineProject) {
        guard offsets.count == 4 else { return }
        let shapes = editableShapes(project.document.expandToGroups(ids), in: project)
        let box = project.bounds(of: Set(shapes.map(\.id)))
        guard !box.isEmpty, box.width > 0, box.height > 0 else { return }
        let corners = [box.min, Vec2(box.max.x, box.min.y), box.max, Vec2(box.min.x, box.max.y)]
        let quad = zip(corners, offsets).map { $0 + $1 }
        let tol = tolerance(project.document.units)
        for s in shapes {
            replacePaths(s.id, with: Distort.envelope(s.paths, box: box, quad: quad, tolerance: tol), operation: "distort", in: &project)
        }
    }

    // MARK: Mirror

    public enum MirrorPivot: String, CaseIterable, Identifiable {
        case selectionCenter, materialCenter, minEdge, maxEdge
        public var id: String { rawValue }
        public func title(horizontally: Bool) -> String {
            switch self {
            case .selectionCenter: return "Selection center"
            case .materialCenter: return "Material center"
            case .minEdge: return horizontally ? "Selection left edge" : "Selection bottom edge"
            case .maxEdge: return horizontally ? "Selection right edge" : "Selection top edge"
            }
        }
    }

    /// Mirror transform: `horizontally` flips left↔right about a vertical line, otherwise
    /// top↔bottom about a horizontal line.
    public static func mirrorTransform(_ ids: Set<UUID>, horizontally: Bool, pivot: MirrorPivot, in project: LoftLineProject) -> Transform2D? {
        let b = project.bounds(of: ids)
        guard !b.isEmpty else { return nil }
        let p: Vec2
        switch pivot {
        case .selectionCenter: p = b.center
        case .materialCenter: p = project.document.job.materialBounds.center
        case .minEdge: p = b.min
        case .maxEdge: p = b.max
        }
        return .mirror(horizontalAxis: !horizontally, about: p)
    }

    /// Mirrors the selection, or adds a mirrored copy when `keepOriginal`. Returns the new
    /// selection (copies) or nil when the originals were mirrored in place.
    @discardableResult
    public static func mirror(_ ids: [UUID], horizontally: Bool, pivot: MirrorPivot, keepOriginal: Bool,
                       in project: inout LoftLineProject) -> [UUID]? {
        let all = project.document.expandToGroups(ids)
        guard let t = mirrorTransform(Set(all), horizontally: horizontally, pivot: pivot, in: project) else { return nil }
        if keepOriginal { return arrayCopies(all, transforms: [t], in: &project) }
        project.transformShapes(Set(all), by: t)
        return nil
    }

    // MARK: Arrays

    /// Adds one copy of the selection per transform (fresh IDs, each copy's groups remapped).
    /// Returns the new shape IDs.
    public static func arrayCopies(_ ids: [UUID], transforms: [Transform2D], in project: inout LoftLineProject) -> [UUID] {
        let shapes = project.document.expandToGroups(ids).compactMap { project.document.shape(id: $0) }
        guard !shapes.isEmpty else { return [] }
        let layers = Set(project.document.layers.map(\.id))
        var newIDs: [UUID] = []
        for t in transforms {
            for var c in ShapeClipboard.copies(of: shapes, offset: .zero, layers: layers, fallbackLayer: shapes[0].layerID) {
                c = c.transformed(t)
                if !t.isConformal { c.origin = .derived(operation: "transform") }
                project.document.add(c)
                newIDs.append(c.id)
            }
        }
        return newIDs
    }

    /// Circular array: `count` items in total (original included) around `center`.
    public static func circularArray(_ ids: [UUID], count: Int, center: Vec2, stepDegrees: Double, rotateCopies: Bool,
                              in project: inout LoftLineProject) -> [UUID] {
        let selCenter = project.bounds(of: Set(project.document.expandToGroups(ids))).center
        let ts = ArrayLayout.circular(count: count, center: center, stepDegrees: stepDegrees, rotateCopies: rotateCopies,
                                      selectionCenter: selCenter)
        return arrayCopies(ids, transforms: ts, in: &project)
    }

    /// Copies the selection (all but the last selected shape) to `count` points along the last
    /// selected shape. The originals are deleted unless `keepOriginal`. Returns the copies.
    public static func copyAlong(_ order: [UUID], count: Int, rotate: Bool, keepOriginal: Bool,
                          in project: inout LoftLineProject) -> [UUID] {
        guard order.count >= 2, let guideID = order.last, let guide = project.document.shape(id: guideID)?.paths.first else { return [] }
        let objects = project.document.expandToGroups(Array(order.dropLast())).filter { $0 != guideID }
        guard !objects.isEmpty else { return [] }
        let c = project.bounds(of: Set(objects)).center
        let ts = CopyAlong.transforms(along: guide, count: count, objectCenter: c, rotate: rotate,
                                      tolerance: tolerance(project.document.units) / 4)
        let ids = arrayCopies(objects, transforms: ts, in: &project)
        if !keepOriginal { project.deleteShapes(Set(objects)) }
        return ids
    }

    /// Rectangular array: rows × columns including the original.
    public static func rectangularArray(_ ids: [UUID], rows: Int, columns: Int, x: Double, y: Double,
                                 spacing: ArrayLayout.Spacing, in project: inout LoftLineProject) -> [UUID] {
        let size = project.bounds(of: Set(project.document.expandToGroups(ids))).size
        let offsets = ArrayLayout.rectangular(rows: rows, columns: columns, x: x, y: y, spacing: spacing, size: size)
        return arrayCopies(ids, transforms: offsets.map { .translation($0) }, in: &project)
    }
}
