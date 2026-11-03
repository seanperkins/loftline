import Foundation

/// DXF (ASCII) import: LINE, ARC, CIRCLE, ELLIPSE, LWPOLYLINE (bulges), POLYLINE, SPLINE
/// (sampled), INSERT (block references); `$INSUNITS` → document units. DXF layers become
/// layers. Loose open entities on the same layer whose ends touch are joined into vectors;
/// vectors that stay open with ends that nearly meet (a gap in the drawing) are reported in `warnings`.
public struct DXFImporter: VectorImporter {
    public static let fileExtensions = ["dxf"]

    /// Endpoint tolerance (in target units) for joining open entities; nil disables joining.
    public var joinTolerance: Double?
    /// Chordal tolerance (in the target units, whatever units the file is in) used to sample splines.
    public var splineTolerance: Double

    public init(joinTolerance: Double? = nil, splineTolerance: Double = 0.001) {
        self.joinTolerance = joinTolerance; self.splineTolerance = splineTolerance
    }

    public func importVectors(from data: Data, targetUnits: LengthUnit) throws -> ImportResult {
        let file = try DXFFile(data: data)
        var warnings: [String] = []
        let scale = unitScale(file, to: targetUnits, warnings: &warnings)
        let toDoc = Transform2D.scale(scale, scale)
        let joinTol = joinTolerance ?? (targetUnits == .inch ? 0.0005 : 0.01)

        var layerOrder: [String] = []
        var pathsByLayer: [String: [Path]] = [:]
        var skipped: [String: Int] = [:]

        // Block references expand at most this many entities in all: the depth cap alone still lets a block that
        // inserts itself k times expand k^16.
        var expansionBudget = Self.maxExpandedEntities
        func collect(_ entities: [DXFEntity], _ t: Transform2D, inheritedLayer: String?, depth: Int) {
            for e in entities {
                let layer = (e.layer == "0" ? inheritedLayer : nil) ?? e.layer
                if depth > 0 { expansionBudget -= 1 }
                if e.type == "INSERT" {
                    guard depth < 16, expansionBudget > 0, let name = e.string(2), let block = file.blocks[name] else {
                        skipped["INSERT", default: 0] += 1; continue
                    }
                    let sx = e.double(41) ?? 1, sy = e.double(42) ?? 1
                    let rot = (e.double(50) ?? 0) * .pi / 180
                    let at = Vec2(e.double(10) ?? 0, e.double(20) ?? 0)
                    var m = Transform2D.translation(-block.base).concatenating(.scale(sx, sy))
                        .concatenating(.rotation(rot)).concatenating(.translation(at))
                    if e.isMirroredOCS { m = m.concatenating(.scale(-1, 1)) }
                    collect(block.entities, m.concatenating(t), inheritedLayer: layer, depth: depth + 1)
                    continue
                }
                // `t` maps the entity to the document (file units, INSERT scale, rotation and mirror), and the
                // tolerance is a length in the document, so the entity is sampled to the tolerance over the most `t`
                // can stretch it.
                guard let paths = DXFGeometry.paths(for: e, splineTolerance: splineTolerance / max(t.maxStretch, 1e-12)) else {
                    skipped[e.type, default: 0] += 1; continue
                }
                guard !paths.isEmpty else { continue }
                if pathsByLayer[layer] == nil { layerOrder.append(layer) }
                pathsByLayer[layer, default: []] += paths.map { $0.transformed(t) }
            }
        }
        collect(file.entities, toDoc, inheritedLayer: nil, depth: 0)
        if expansionBudget <= 0 {
            warnings.append("Block references expand to more than \(Self.maxExpandedEntities) entities; the rest were not imported.")
        }

        for (type, n) in skipped.sorted(by: { $0.key < $1.key }) {
            warnings.append("Skipped \(n) unsupported \(type) entit\(n == 1 ? "y" : "ies").")
        }

        var layers: [Layer] = []
        var shapes: [Shape] = []
        for name in layerOrder {
            let layer = Layer(name: name, colorHex: color(file.layerColors[name], index: layers.count))
            layers.append(layer)
            var paths = pathsByLayer[name] ?? []
            if joinTol > 0 {
                paths = PathOps.joinOpenPaths(paths, tolerance: joinTol)
                if let gaps = PathOps.nearlyMeetingEnds(paths, beyond: joinTol, upTo: joinTol * Self.nearMissFactor) {
                    warnings.append(Self.gapWarning(layer: name, gaps: gaps, joinTolerance: joinTol, units: targetUnits))
                }
            }
            for p in paths {
                shapes.append(Shape(name: p.isClosed ? "Closed vector" : "Open vector", layerID: layer.id,
                                    paths: [p], origin: .imported(format: "dxf")))
            }
        }
        return ImportResult(layers: layers, shapes: shapes, warnings: warnings)
    }

    /// Open ends further apart than the join tolerance but within this many times it are reported:
    /// that is a slip in the drawing, where a lone open line (engraving, a V-carve centerline) is not.
    public static let nearMissFactor = 100.0
    /// The most entities block references (INSERT) may expand to in one file; past it, further INSERTs are skipped.
    public static let maxExpandedEntities = 100_000

    /// "Layer "Cabinet": 2 open vectors have ends that nearly meet, 0.1 to 0.4 mm apart. ..."
    static func gapWarning(layer: String, gaps: PathOps.EndGapReport, joinTolerance: Double, units: LengthUnit) -> String {
        func length(_ v: Double) -> String { String(format: "%.2g", v) }
        let lo = length(gaps.smallestGap), hi = length(gaps.largestGap)
        let apart = lo == hi ? lo : "\(lo) to \(hi)"
        let n = gaps.vectorCount
        return "Layer \"\(layer)\": \(n) open vector\(n == 1 ? " has" : "s have") ends that nearly meet, "
            + "\(apart) \(units.abbreviation) apart. The import joins ends within \(length(joinTolerance)) "
            + "\(units.abbreviation), so \(n == 1 ? "it stayed" : "they stayed") open; "
            + "a gap in the source drawing is the usual cause."
    }

    /// Scale factor from DXF drawing units to `target`.
    func unitScale(_ file: DXFFile, to target: LengthUnit, warnings: inout [String]) -> Double {
        let mm: Double?
        switch file.headerInt("$INSUNITS") {
        case 1: mm = 25.4
        case 2: mm = 304.8
        case 4: mm = 1
        case 5: mm = 10
        case 6: mm = 1000
        case 8: mm = 25.4e-6
        case 9: mm = 25.4e-3
        case 13: mm = 1e-3
        case 14: mm = 100
        default:
            switch file.headerInt("$MEASUREMENT") {
            case 0: mm = 25.4
            case 1: mm = 1
            default: mm = nil
            }
        }
        guard let mm else {
            warnings.append("DXF has no units; values were read as \(target == .inch ? "inches" : "millimetres").")
            return 1
        }
        return mm / target.millimeters
    }

    /// AutoCAD Color Index 1–7 → hex; other indices fall back to a palette.
    func color(_ aci: Int?, index: Int) -> String {
        let basic = [1: "#FF0000", 2: "#FFFF00", 3: "#00FF00", 4: "#00FFFF", 5: "#0000FF", 6: "#FF00FF", 7: "#000000"]
        if let aci, let hex = basic[aci] { return hex }
        return SVGImporter.palette[index % SVGImporter.palette.count]
    }
}
