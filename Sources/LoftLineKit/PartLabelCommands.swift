import CADCore
import CAMCore
import Foundation

/// What a part label says.
public enum PartLabelText: String, CaseIterable, Identifiable {
    case numbers, names, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .numbers: return "Number"
        case .names: return "Name"
        case .both: return "Number and name"
        }
    }
}

/// Design > Layout > Label Parts….
public struct PartLabelOptions: Equatable {
    public var text: PartLabelText = .numbers
    /// Largest letter (cap) height; labels shrink to fit small parts.
    public var maxHeight: Double
    /// Labels smaller than this are skipped (too small to engrave legibly).
    public var minHeight: Double
    public var fontName = "Helvetica"
    /// Also create a V-Carve toolpath for the labels.
    public var addToolpath = false

    public static func defaults(for units: LengthUnit) -> PartLabelOptions {
        units == .inch ? PartLabelOptions(maxHeight: 0.5, minHeight: 0.08) : PartLabelOptions(maxHeight: 12, minHeight: 2)
    }
}

public struct PartLabelReport: Equatable {
    public var labelIDs: [UUID]
    public var skipped: Int
    public var operationID: UUID?
}

public enum PartLabelCommands {
    public static let layerName = "Part Labels"

    /// Names unnamed parts "Part N", writes a label (number and/or name) at the roomiest spot of
    /// each part on the "Part Labels" layer, replacing labels made earlier for those parts.
    public static func label(_ ids: [UUID], options o: PartLabelOptions, library: ToolLibrary,
                      in project: inout LoftLineProject) throws -> PartLabelReport {
        let doc = project.document
        let labelLayer = doc.layers.first { $0.name == layerName && $0.sheet == nil && $0.keepOut == nil }?.id
        let skipLayers = Fixtures.keepOutLayerIDs(in: doc).union(labelLayer.map { [$0] } ?? [])
        let shapes = doc.shapes(ids: doc.expandToGroups(ids)).filter { !skipLayers.contains($0.layerID) }
        let tol = doc.units == .inch ? 0.002 : 0.05
        let parts = NestPartBuilder.parts(from: shapes, tolerance: tol)
        guard !parts.isEmpty else { return PartLabelReport(labelIDs: [], skipped: 0) }

        // Remove earlier labels that sit on these parts.
        if let l = labelLayer {
            let old = doc.shapes.filter { s in
                s.layerID == l && parts.contains { part in
                    part.outline.contains { PathGeometry.contains($0, s.bounds().center) }
                }
            }
            project.deleteShapes(Set(old.map(\.id)))
        }
        let layer = labelLayer ?? project.addLayer(named: layerName)

        var labelIDs: [UUID] = [], skipped = 0
        let outliner = TextOutliner()
        for (k, part) in parts.enumerated() {
            let number = k + 1
            let members = part.shapeIDs.compactMap { project.document.shape(id: $0) }
            guard let primary = members.max(by: { area($0.bounds()) < area($1.bounds()) }) else { continue }
            if primary.name.isEmpty, let i = project.document.shapes.firstIndex(where: { $0.id == primary.id }) {
                project.document.shapes[i].name = "Part \(number)"
            }
            let name = project.document.shape(id: primary.id)?.name ?? "Part \(number)"
            let text: String
            switch o.text {
            case .numbers: text = "\(number)"
            case .names: text = name
            case .both: text = "\(number) \(name)"
            }
            // Room for the label: the part minus its features (members lying strictly inside
            // the outline's bounds; members that form the outline touch its bounds).
            var region = part.outline
            var lines: [[Vec2]] = []
            let inner = Rect2(points: part.outline.joined()).insetBy(tol)
            for s in members {
                let b = s.bounds()
                guard !inner.isEmpty, inner.contains(b.min), inner.contains(b.max) else { continue }
                for p in s.paths {
                    let pts = p.flattened(tolerance: tol)
                    if p.isClosed { region.append(pts) } else { lines.append(pts) }
                }
            }
            guard let spot = PartLabels.labelPoint(region: region, obstacles: lines) else { skipped += 1; continue }
            let probe = try outliner.outlines(for: text, fontName: o.fontName, size: o.maxHeight, origin: .zero,
                                              alignment: .center)
            let pb = probe.reduce(Rect2.empty) { $0.union($1.bounds()) }
            guard !pb.isEmpty else { skipped += 1; continue }
            let diag = (pb.width * pb.width + pb.height * pb.height).squareRoot()
            let size = o.maxHeight * min(1, 0.9 * 2 * spot.clearance / max(diag, 1e-9))
            guard size >= o.minHeight else { skipped += 1; continue }
            var shape = try outliner.shape(for: text, fontName: o.fontName, size: size, origin: .zero,
                                           alignment: .center, layerID: layer)
            shape = shape.transformed(.translation(spot.point - shape.bounds().center))
            shape.name = "Label \(text)"
            project.document.add(shape)
            labelIDs.append(shape.id)
        }

        var opID: UUID?
        if o.addToolpath, !labelIDs.isEmpty,
           var op = OperationFactory.make(kind: .vcarve, project: project, library: library, shapeIDs: labelIDs) {
            var s = op.editableSetup
            s.name = "Part Labels"
            op.editableSetup = s
            project.upsertOperation(op)
            opID = op.id
        }
        return PartLabelReport(labelIDs: labelIDs, skipped: skipped, operationID: opID)
    }

    private static func area(_ r: Rect2) -> Double { r.width * r.height }
}
