import CADCore
import CAMCore
import Foundation

/// Options for File > Import 3D Model as 2D Parts… (SketchUp-style cut parts: each solid of a
/// COLLADA/STL/OBJ model becomes a closed outline to cut).
public struct ModelPartsForm: Equatable, Identifiable {
    public let id = UUID()
    public var fileName: String
    public var parts: [MeshPart]
    public var view: MeshParts.View = .flat
    /// Space between laid-out parts, document units.
    public var gap: Double
    /// One layer per part thickness ("Parts 0.75 in"), so each board thickness can get its own
    /// toolpaths; otherwise one layer named after the file.
    public var layerPerThickness = true

    public init(fileName: String, parts: [MeshPart], units: LengthUnit) {
        self.fileName = fileName
        self.parts = parts
        gap = units == .inch ? 0.5 : 12
    }

    public static let allowedExtensions = ["dae", "stl", "obj"]

    /// Reads the model's parts: COLLADA scene nodes (SketchUp groups/components), or the
    /// connected pieces of an STL/OBJ mesh.
    public static func read(data: Data, fileName: String, units: LengthUnit) throws -> ModelPartsForm {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        let parts: [MeshPart]
        if ext == "dae" {
            parts = try DAEImporter().importParts(from: data, targetUnits: units)
        } else if ext == "skp" {
            throw LoftLineIOError.unsupportedFormat("skp")
        } else {
            let mesh = try ImportService.meshImporter(for: fileName).importMesh(from: data, targetUnits: units)
            guard mesh.triangleCount > 0 else { throw LoftLineIOError.malformed("the model contains no triangles") }
            parts = MeshParts.connectedComponents(mesh, name: base.isEmpty ? "Part" : base)
        }
        return ModelPartsForm(fileName: fileName, parts: parts, units: units)
    }

    public static func viewTitle(_ v: MeshParts.View) -> String {
        switch v {
        case .flat: return "Flat parts (each on its largest face)"
        case .top: return "Top view, as assembled"
        case .front: return "Front view, as assembled"
        case .right: return "Right view, as assembled"
        }
    }

    /// "0.75 in" style thickness label rounded to 1/1000 in or 0.1 mm.
    public static func thicknessLabel(_ t: Double, units: LengthUnit) -> String {
        let r = units == .inch ? (t * 1000).rounded() / 1000 : (t * 10).rounded() / 10
        return "\(decimalFormat.format(r)) \(units.abbreviation)"
    }

    /// Adds the outlines as closed vectors (one shape per part) and returns their ids.
    public func apply(to project: inout LoftLineProject) -> ImportOutcome {
        let units = project.document.units
        let outlines = MeshParts.layout(parts, view: view, area: project.document.job.materialBounds, gap: gap)
        var outcome = ImportOutcome()
        let skipped = parts.count - outlines.count
        if skipped > 0 { outcome.warnings.append("\(skipped) part(s) had no area in this view and were skipped.") }
        let base = (fileName as NSString).deletingPathExtension
        var layers: [String: UUID] = [:]
        func layer(_ name: String) -> UUID {
            if let id = layers[name] { return id }
            let id = project.document.layers.first(where: { $0.name == name })?.id ?? project.addLayer(named: name)
            layers[name] = id
            return id
        }
        for o in outlines {
            let thick = Self.thicknessLabel(o.thickness, units: units)
            let layerName = layerPerThickness && view == .flat ? "Parts \(thick)" : (base.isEmpty ? "Parts" : base)
            let shape = Shape(name: view == .flat ? "\(o.name) (\(thick))" : o.name, layerID: layer(layerName),
                              paths: o.paths, origin: .imported(format: "3d-parts"))
            project.document.add(shape)
            outcome.shapeIDs.append(shape.id)
        }
        if view == .flat, let maxY = outlines.map(\.bounds.max.y).max(), maxY > project.document.job.materialBounds.max.y {
            outcome.warnings.append("The parts do not all fit on the material; use Nest Parts or a larger sheet.")
        }
        return outcome
    }

    /// Thickness → part count, thinnest first, for the dialog summary.
    public func thicknessSummary(units: LengthUnit) -> [(String, Int)] {
        var counts: [String: (Double, Int)] = [:]
        for p in parts {
            guard let o = MeshParts.outline(of: p, view: .flat) else { continue }
            let label = Self.thicknessLabel(o.thickness, units: units)
            counts[label] = (o.thickness, (counts[label]?.1 ?? 0) + 1)
        }
        return counts.sorted { $0.value.0 < $1.value.0 }.map { ($0.key, $0.value.1) }
    }
}
