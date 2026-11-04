import CADCore
import Foundation

/// Canvas interaction modes.
public enum CanvasTool: String, CaseIterable, Identifiable {
    case select, nodeEdit, rectangle, roundedRectangle, circle, ellipse, polygon, star, polyline, pen, curve, arc, freehand, text, trim, measure, dimension

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .nodeEdit: return "Node Edit"
        case .rectangle: return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .polygon: return "Polygon"
        case .star: return "Star"
        case .polyline: return "Line / Polyline"
        case .pen: return "Bézier Pen"
        case .curve: return "Smooth Curve"
        case .arc: return "Arc"
        case .trim: return "Trim"
        case .freehand: return "Freehand"
        case .measure: return "Measure"
        case .dimension: return "Dimension"
        case .text: return "Text"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .nodeEdit: return "point.topleft.down.to.point.bottomright.filled.curvepath"
        case .rectangle: return "rectangle"
        case .roundedRectangle: return "app"
        case .circle: return "circle"
        case .ellipse: return "oval"
        case .polygon: return "hexagon"
        case .star: return "star"
        case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pen: return "pencil.tip"
        case .curve: return "scribble.variable"
        case .arc: return "circle.bottomhalf.filled"
        case .trim: return "scissors"
        case .freehand: return "hand.draw"
        case .measure: return "ruler"
        case .dimension: return "arrow.left.and.right"
        case .text: return "textformat"
        }
    }

    /// The palette's rows, separated by dividers: selecting and editing, closed shapes, lines and curves, and
    /// annotation. Together they list every tool once, in palette order.
    public static let groups: [[CanvasTool]] = [
        [.select, .nodeEdit],
        [.rectangle, .roundedRectangle, .circle, .ellipse, .polygon, .star],
        [.polyline, .pen, .curve, .arc, .freehand],
        [.text, .trim, .measure, .dimension],
    ]

    /// Drawn by `ToolGlyph` instead of an SF Symbol, because no symbol reads as an arc.
    public var hasCustomGlyph: Bool { self == .arc }

    /// Single-key shortcut on the canvas (VCarve/Illustrator-like).
    public var shortcut: Character? {
        switch self {
        case .select: return "v"
        case .nodeEdit: return "n"
        case .rectangle: return "r"
        case .circle: return "c"
        case .ellipse: return "e"
        case .polyline: return "l"
        case .pen: return "p"
        case .text: return "t"
        case .arc: return "a"
        case .trim: return "x"
        case .measure: return "m"
        default: return nil
        }
    }

    public static func forShortcut(_ c: Character) -> CanvasTool? { allCases.first { $0.shortcut == c } }

    /// Tools whose shapes are built from successive clicks.
    public var isClickBuilt: Bool { self == .polyline || self == .curve || self == .pen || self == .arc || self == .dimension }

    /// Tools created by click-dragging a box/radius.
    public var isDragShape: Bool {
        switch self {
        case .rectangle, .roundedRectangle, .circle, .ellipse, .polygon, .star: return true
        default: return false
        }
    }
}

/// User-adjustable options for the drawing tools (shown in the inspector while a tool is active).
public struct DrawingOptions: Equatable {
    public var cornerRadius: Double = 0.25
    public var polygonSides = 6
    public var starPoints = 5
    public var starInnerRatio = 0.5
    public var text = "LoftLine"
    public var fontName = "Helvetica"
    public var fontSize = 1.0
    public var textAlignment = CADCore.TextAlignment.left
    public var lineSpacing = 1.0
    public var letterSpacing = 0.0
    /// Arc tool: true = centre, start, end; false = start, end, point on the arc.
    public var arcFromCenter = false
    /// Exact arc entry (inspector).
    public var arcRadius = 2.0
    public var arcStartAngle = 0.0
    public var arcEndAngle = 90.0
    public var dimensionKind = DimensionAnnotation.Kind.aligned
    /// Shift-drag style constraint (square/circle) applied by the canvas.
    public var constrain = false
    /// Numeric creation (inspector): centre and size in document units. Circles, polygons and
    /// stars use `exactWidth` as the diameter.
    public var exactCenter = Vec2(6, 6)
    public var exactWidth = 4.0
    public var exactHeight = 2.0
    /// Node tool: symmetric editing about the shape's centre lines.
    public var nodeMirror = NodeMirrorMode.off

    public init(cornerRadius: Double = 0.25, polygonSides: Int = 6, starPoints: Int = 5, starInnerRatio: Double = 0.5, text: String = "LoftLine", fontName: String = "Helvetica", fontSize: Double = 1.0, textAlignment: CADCore.TextAlignment = CADCore.TextAlignment.left, lineSpacing: Double = 1.0, letterSpacing: Double = 0.0, arcFromCenter: Bool = false, arcRadius: Double = 2.0, arcStartAngle: Double = 0.0, arcEndAngle: Double = 90.0, dimensionKind: DimensionAnnotation.Kind = DimensionAnnotation.Kind.aligned, constrain: Bool = false, exactCenter: Vec2 = Vec2(6, 6), exactWidth: Double = 4.0, exactHeight: Double = 2.0, nodeMirror: NodeMirrorMode = NodeMirrorMode.off) {
        self.cornerRadius = cornerRadius
        self.polygonSides = polygonSides
        self.starPoints = starPoints
        self.starInnerRatio = starInnerRatio
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.textAlignment = textAlignment
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        self.arcFromCenter = arcFromCenter
        self.arcRadius = arcRadius
        self.arcStartAngle = arcStartAngle
        self.arcEndAngle = arcEndAngle
        self.dimensionKind = dimensionKind
        self.constrain = constrain
        self.exactCenter = exactCenter
        self.exactWidth = exactWidth
        self.exactHeight = exactHeight
        self.nodeMirror = nodeMirror
    }
}

/// Builds shapes from canvas gestures (document coordinates). Pure, unit-agnostic.
public enum DrawingTools {
    /// Shape for a drag from `a` to `b`. Box tools use the drag as a corner-to-corner box;
    /// radial tools (circle/polygon/star) use `a` as the centre.
    public static func shape(for tool: CanvasTool, from a: Vec2, to b: Vec2, options: DrawingOptions,
                      layerID: UUID) -> Shape? {
        var box = Rect2(points: [a, b])
        if options.constrain {
            let s = max(box.width, box.height)
            box = Rect2(min: Vec2(b.x >= a.x ? a.x : a.x - s, b.y >= a.y ? a.y : a.y - s), max: .zero)
            box.max = box.min + Vec2(s, s)
        }
        let radius = a.distance(to: b)
        switch tool {
        case .rectangle:
            guard box.width > 0, box.height > 0 else { return nil }
            return Shape(name: "Rectangle", layerID: layerID, paths: [ShapeFactory.rectangle(box)],
                         origin: .rectangle(width: box.width, height: box.height, cornerRadius: 0))
        case .roundedRectangle:
            guard box.width > 0, box.height > 0 else { return nil }
            let r = min(options.cornerRadius, min(box.width, box.height) / 2)
            return Shape(name: "Rounded Rectangle", layerID: layerID,
                         paths: [ShapeFactory.rectangle(box, cornerRadius: r)],
                         origin: .rectangle(width: box.width, height: box.height, cornerRadius: r))
        case .circle:
            guard radius > 0 else { return nil }
            return Shape(name: "Circle", layerID: layerID, paths: [ShapeFactory.circle(center: a, radius: radius)],
                         origin: .circle(radius: radius))
        case .ellipse:
            guard box.width > 0, box.height > 0 else { return nil }
            let rx = box.width / 2, ry = box.height / 2
            return Shape(name: "Ellipse", layerID: layerID,
                         paths: [ShapeFactory.ellipse(center: box.center, rx: rx, ry: ry)], origin: .ellipse(rx: rx, ry: ry))
        case .polygon:
            guard radius > 0 else { return nil }
            let rot = (b - a).angle
            return Shape(name: "Polygon", layerID: layerID,
                         paths: [ShapeFactory.polygon(center: a, radius: radius, sides: options.polygonSides, rotation: rot)],
                         origin: .polygon(sides: max(3, options.polygonSides), radius: radius))
        case .star:
            guard radius > 0 else { return nil }
            let inner = radius * min(max(options.starInnerRatio, 0.05), 0.95)
            return Shape(name: "Star", layerID: layerID,
                         paths: [ShapeFactory.star(center: a, points: options.starPoints, outerRadius: radius,
                                                   innerRadius: inner, rotation: (b - a).angle)],
                         origin: .star(points: max(2, options.starPoints), outerRadius: radius, innerRadius: inner))
        default:
            return nil
        }
    }

    /// Shape of an exact size centred on `center` (numeric entry). Box tools use width × height;
    /// radial tools use `width` as the diameter (outer diameter for stars).
    public static func exactShape(for tool: CanvasTool, center c: Vec2, width w: Double, height h: Double,
                           options: DrawingOptions, layerID: UUID) -> Shape? {
        guard w > 0 else { return nil }
        var o = options
        o.constrain = false
        switch tool {
        case .rectangle, .roundedRectangle, .ellipse:
            guard h > 0 else { return nil }
            return shape(for: tool, from: c - Vec2(w / 2, h / 2), to: c + Vec2(w / 2, h / 2), options: o, layerID: layerID)
        case .circle, .polygon, .star:
            return shape(for: tool, from: c, to: c + Vec2(0, w / 2), options: o, layerID: layerID)
        default:
            return nil
        }
    }

    /// Arc from three clicks: start, end, point on the arc — or, `fromCenter`, centre, start
    /// (radius) and a point giving the end direction (counter-clockwise).
    public static func arc(points: [Vec2], fromCenter: Bool, layerID: UUID) -> Shape? {
        guard points.count >= 3 else { return nil }
        let p = fromCenter ? ArcConstruction.centerStartEnd(center: points[0], start: points[1], endDirection: points[2])
                           : ArcConstruction.threePoint(start: points[0], end: points[1], through: points[2])
        return p.map { Shape(name: "Arc", layerID: layerID, paths: [$0]) }
    }

    /// Freehand stroke: the dragged points are simplified (`tolerance`) and smoothed into Bézier
    /// curves; the stroke closes when it ends within `closeTolerance` of its start.
    public static func freehand(points: [Vec2], tolerance: Double, closeTolerance: Double, layerID: UUID) -> Shape? {
        guard points.count >= 2 else { return nil }
        var pts = BitmapTracer.simplifyPolyline(points, tolerance: max(tolerance, 1e-9))
        guard pts.count >= 2, pts.first!.distance(to: pts.last!) > 0 || pts.count > 2 else { return nil }
        let closes = pts.count >= 4 && pts.last!.distance(to: pts[0]) <= closeTolerance
        if closes { pts[pts.count - 1] = pts[0] }
        guard var s = smoothCurve(points: pts, closeTolerance: closes ? closeTolerance : 0, layerID: layerID) else { return nil }
        s.name = "Freehand"
        return s
    }

    /// Polyline from clicked points; closes when the last point returns to the first.
    public static func polyline(points: [Vec2], closeTolerance: Double, layerID: UUID) -> Shape? {
        var pts = points
        // Drop consecutive duplicates (double-click adds the same point twice).
        pts = pts.enumerated().filter { $0.offset == 0 || !$0.element.isApproximatelyEqual(to: pts[$0.offset - 1], tolerance: 1e-9) }.map(\.element)
        guard pts.count >= 2 else { return nil }
        var closed = false
        if pts.count >= 3, pts.last!.distance(to: pts[0]) <= closeTolerance {
            pts.removeLast(); closed = true
        }
        guard pts.count >= 2 else { return nil }
        return Shape(name: closed ? "Polygon" : "Polyline", layerID: layerID,
                     paths: [Path(points: pts, closed: closed && pts.count >= 3)])
    }

    /// Smooth open/closed curve through clicked points (Catmull-Rom converted to cubic Béziers).
    public static func smoothCurve(points: [Vec2], closeTolerance: Double, layerID: UUID) -> Shape? {
        var pts = points
        guard pts.count >= 2 else { return nil }
        var closed = false
        if pts.count >= 4, pts.last!.distance(to: pts[0]) <= closeTolerance { pts.removeLast(); closed = true }
        let n = pts.count
        func p(_ i: Int) -> Vec2 {
            if closed { return pts[((i % n) + n) % n] }
            return pts[min(max(i, 0), n - 1)]
        }
        var segs: [PathSegment] = []
        let count = closed ? n : n - 1
        for i in 0..<count {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            let c1 = p1 + (p2 - p0) / 6
            let c2 = p2 - (p3 - p1) / 6
            segs.append(.cubic(to: p2, control1: c1, control2: c2))
        }
        return Shape(name: "Curve", layerID: layerID, paths: [Path(start: pts[0], segments: segs, isClosed: closed)])
    }
}
