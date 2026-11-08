import CADCore
import CAMCore
import Foundation

/// Design > Layout > Clamps and Fixture Holes…: clamp footprints along the material edges.
public struct ClampOptions: Equatable {
    public var length: Double
    public var reach: Double
    public var outside: Double
    public var perSideEdge = 2
    public var perEndEdge = 0
    public var endInset: Double
    /// Clamp height above the material top.
    public var height: Double

    public static func defaults(for units: LengthUnit) -> ClampOptions {
        let f = units == .inch ? 1 : 25.4
        return ClampOptions(length: 3 * f, reach: 0.75 * f, outside: 1.5 * f, endInset: 2 * f, height: 1.25 * f)
    }
}

/// A grid of fixture holes: screws to keep clear of, or holes to drill (e.g. dowels).
public struct HoleOptions: Equatable {
    public var diameter: Double
    public var spacingX: Double
    public var spacingY: Double
    public var inset: Double
    /// True: screws holding the work down (keep-out zones). False: holes to drill.
    public var keepOut = true

    public static func defaults(for units: LengthUnit) -> HoleOptions {
        let f = units == .inch ? 1 : 25.4
        return HoleOptions(diameter: 0.5 * f, spacingX: 12 * f, spacingY: 12 * f, inset: 1 * f)
    }
}

public enum FixtureCommands {
    /// Adds clamp rectangles on the "Clamps" keep-out layer (created if missing; an existing
    /// one gets the new clamp height). Returns the new shape IDs.
    public static func addClamps(_ o: ClampOptions, in project: inout LoftLineProject) -> [UUID] {
        let rects = Fixtures.clampRects(job: project.document.job, length: max(0, o.length), reach: max(0, o.reach),
                                        outside: max(0, o.outside), perSideEdges: max(0, o.perSideEdge),
                                        perEndEdges: max(0, o.perEndEdge), endInset: max(0, o.endInset))
        guard !rects.isEmpty, o.length > 0 else { return [] }
        let layer = keepOutLayer(named: "Clamps", height: max(0, o.height), in: &project)
        let first = nextNumber("Clamp ", on: layer, in: project.document)
        return rects.enumerated().map { i, r in
            let s = Shape(name: "Clamp \(first + i)", layerID: layer, paths: [ShapeFactory.rectangle(r)],
                          origin: .rectangle(width: r.width, height: r.height, cornerRadius: 0))
            project.document.add(s)
            return s.id
        }
    }

    /// Adds a hole grid over the material: keep-out circles on "Screws", or plain circles on a
    /// "Fixture Holes" layer ready for a Drilling toolpath.
    public static func addHoles(_ o: HoleOptions, in project: inout LoftLineProject) -> [UUID] {
        guard o.diameter > 0 else { return [] }
        let job = project.document.job
        let centres = Fixtures.holeGrid(in: job.materialBounds, spacing: Vec2(o.spacingX, o.spacingY), inset: max(0, o.inset))
        guard !centres.isEmpty else { return [] }
        let layer: UUID
        if o.keepOut {
            layer = keepOutLayer(named: "Screws", height: 0, in: &project)
        } else if let l = project.document.layers.first(where: { $0.name == "Fixture Holes" && $0.keepOut == nil && $0.sheet == nil }) {
            layer = l.id
        } else {
            layer = project.addLayer(named: "Fixture Holes")
        }
        let prefix = o.keepOut ? "Screw " : "Hole "
        let first = nextNumber(prefix, on: layer, in: project.document)
        return centres.enumerated().map { i, c in
            let s = Shape(name: prefix + "\(first + i)", layerID: layer,
                          paths: [ShapeFactory.circle(center: c, radius: o.diameter / 2)],
                          origin: .circle(radius: o.diameter / 2))
            project.document.add(s)
            return s.id
        }
    }

    /// One past the highest "<prefix>N" already on the layer, so running the command again numbers on ("Clamp 7") and every clamp
    /// keeps a name of its own on the job sheet and canvas.
    static func nextNumber(_ prefix: String, on layer: UUID, in doc: Document) -> Int {
        let used = doc.shapes.filter { $0.layerID == layer && $0.name.hasPrefix(prefix) }.compactMap { Int($0.name.dropFirst(prefix.count)) }
        return (used.max() ?? 0) + 1
    }

    /// The keep-out layer called `name` (red), created
    /// when missing; its clamp height is set to `height`.
    public static func keepOutLayer(named name: String, height: Double, in project: inout LoftLineProject) -> UUID {
        if let i = project.document.layers.firstIndex(where: { $0.name == name && $0.keepOut != nil }) {
            project.document.layers[i].keepOut = LayerKeepOut(height: height)
            return project.document.layers[i].id
        }
        let l = Layer(name: name, colorHex: "#D0312D", keepOut: LayerKeepOut(height: height))
        project.document.layers.append(l)
        return l.id
    }
}
