import CADCore
import CAMCore
import Foundation

/// Settings of Design > Layout > Production Plates….
public struct ProductionPlateOptions: Equatable {
    /// Plates per row; nil = as many as fit across the material.
    public var columns: Int?
    public var gapX: Double
    public var gapY: Double
    /// New rows go below the template (else above).
    public var rowsDown = true
    /// Shrink filled-in text that is wider/taller than the plate it sits on (less `margin`).
    public var shrinkToFit = true
    public var margin: Double
    /// Add each plate's vectors to the toolpaths that machine the template.
    public var includeToolpaths = true

    public static func defaults(for units: LengthUnit) -> ProductionPlateOptions {
        units == .inch ? ProductionPlateOptions(gapX: 0.5, gapY: 0.5, margin: 0.25)
            : ProductionPlateOptions(gapX: 12, gapY: 12, margin: 6)
    }
}

public struct ProductionPlateReport: Equatable {
    public var plates: Int
    /// Every shape of every plate (template included), for the new selection.
    public var shapeIDs: [UUID]
    /// Placeholders that no spreadsheet column matched (left as typed).
    public var missingFields: [String]
    /// Plates that reach past the material.
    public var outsideMaterial: Int
    /// Toolpaths that now machine the plates.
    public var operationsUpdated: Int
    /// Texts that were made smaller to fit their plate.
    public var shrunk: Int

    public var summary: String {
        var s = "\(plates) plate\(plates == 1 ? "" : "s")"
        if operationsUpdated > 0 { s += ", added to \(operationsUpdated) toolpath\(operationsUpdated == 1 ? "" : "s")" }
        if shrunk > 0 { s += ", \(shrunk) text\(shrunk == 1 ? "" : "s") shrunk to fit" }
        return s + "."
    }
}

public enum ProductionPlateCommands {
    public enum Failure: LocalizedError {
        case noTemplate, noRecords, noPlaceholders
        public var errorDescription: String? {
            switch self {
            case .noTemplate: return "Select the plate design (its outline and text) first."
            case .noRecords: return "The spreadsheet has no rows below its header row."
            case .noPlaceholders: return "None of the selected text contains a {Field} placeholder."
            }
        }
    }

    /// Editable shapes of the template (selection expanded to whole groups).
    public static func template(_ ids: [UUID], in project: LoftLineProject) -> [Shape] {
        project.document.shapes(ids: project.document.expandToGroups(ids)).filter(project.isEditable)
    }

    /// Placeholder names used by the template's live text.
    public static func fields(_ ids: [UUID], in project: LoftLineProject) -> [String] {
        var out: [String] = []
        for s in template(ids, in: project) {
            for f in ProductionPlates.fields(in: s.text?.string ?? "") where !out.contains(f) { out.append(f) }
        }
        return out
    }

    /// Makes one plate per spreadsheet record: the template becomes the first record's plate and
    /// copies for the rest are laid out in a grid, each with `{Field}` placeholders in its live
    /// text replaced by that record's values. With `includeToolpaths`, every toolpath that
    /// machines a template vector also machines the matching vector of every plate.
    public static func make(_ ids: [UUID], table: CSVTable, options o: ProductionPlateOptions,
                     in project: inout LoftLineProject) throws -> ProductionPlateReport {
        let shapes = template(ids, in: project)
        guard !shapes.isEmpty else { throw Failure.noTemplate }
        guard !table.rows.isEmpty else { throw Failure.noRecords }
        guard shapes.contains(where: { !ProductionPlates.fields(in: $0.text?.string ?? "").isEmpty }) else {
            throw Failure.noPlaceholders
        }
        let box = shapes.reduce(Rect2.empty) { $0.union($1.bounds()) }
        let material = project.document.job.materialBounds
        let columns = o.columns ?? ProductionPlates.columnsThatFit(template: box, gapX: o.gapX, material: material)
        let pitch = ProductionPlates.pitch(size: box.size, gap: Vec2(o.gapX, o.gapY))
        let frames = textFrames(shapes)
        let layers = Set(project.document.layers.map(\.id))
        let outliner = TextOutliner()

        var copiesOf: [UUID: [UUID]] = [:]
        var all: [UUID] = [], missing: [String] = []
        var outside = 0, shrunk = 0
        for k in table.rows.indices {
            let record = table.record(k)
            let offset = ProductionPlates.offset(index: k, columns: columns, pitch: pitch, rowsDown: o.rowsDown)
            var plate = k == 0 ? shapes
                : ShapeClipboard.copies(of: shapes, offset: offset, layers: layers, fallbackLayer: shapes[0].layerID)
            for j in plate.indices {
                guard var spec = plate[j].text, !ProductionPlates.fields(in: spec.string).isEmpty else { continue }
                let filled = ProductionPlates.fill(spec.string, record: record)
                for m in filled.missing where !missing.contains(m) { missing.append(m) }
                spec.string = filled.text
                var s = try outliner.shape(for: spec, layerID: plate[j].layerID)
                if o.shrinkToFit, let frame = frames[shapes[j].id] {
                    let room = frame.translated(by: offset).insetBy(o.margin)
                    let b = s.bounds()
                    let f = min(room.width / max(b.width, 1e-12), room.height / max(b.height, 1e-12))
                    if room.width > 0, room.height > 0, f < 1 {
                        let anchor = Vec2(spec.transform.tx, spec.transform.ty)
                        spec.transform = spec.transform.concatenating(.scale(f, f, about: anchor))
                        s = try outliner.shape(for: spec, layerID: plate[j].layerID)
                        shrunk += 1
                    }
                }
                plate[j].paths = s.paths
                plate[j].origin = s.origin
                plate[j].text = spec
                plate[j].name = s.name
            }
            for (j, s) in plate.enumerated() {
                if k == 0 {
                    if let i = project.document.shapes.firstIndex(where: { $0.id == s.id }) { project.document.shapes[i] = s }
                } else {
                    project.document.add(s)
                    copiesOf[shapes[j].id, default: []].append(s.id)
                }
                all.append(s.id)
            }
            let pb = plate.reduce(Rect2.empty) { $0.union($1.bounds()) }
            if pb.min.x < material.min.x - 1e-9 || pb.min.y < material.min.y - 1e-9
                || pb.max.x > material.max.x + 1e-9 || pb.max.y > material.max.y + 1e-9 { outside += 1 }
        }

        var updated = 0
        if o.includeToolpaths, !copiesOf.isEmpty {
            for i in project.operations.indices where addCopies(copiesOf, to: &project.operations[i]) { updated += 1 }
        }
        return ProductionPlateReport(plates: table.rows.count, shapeIDs: all, missingFields: missing,
                                     outsideMaterial: outside, operationsUpdated: updated, shrunk: shrunk)
    }

    /// For each live text in the template, the bounds of the smallest closed non-text shape that
    /// contains the text's centre (the plate it sits on).
    public static func textFrames(_ shapes: [Shape]) -> [UUID: Rect2] {
        let frames = shapes.filter { $0.text == nil && $0.paths.contains(where: \.isClosed) }.map { $0.bounds() }
        var out: [UUID: Rect2] = [:]
        for s in shapes where s.text != nil {
            let c = s.bounds().center
            if let f = frames.filter({ $0.contains(c) }).min(by: { $0.width * $0.height < $1.width * $1.height }) {
                out[s.id] = f
            }
        }
        return out
    }

    /// Appends the plate copies of the operation's template vectors (merges: every part).
    /// Returns true when something was added.
    public static func addCopies(_ copiesOf: [UUID: [UUID]], to op: inout AnyOperation) -> Bool {
        var changed = false
        if case .merge(var m) = op {
            for c in m.params.children.indices where addCopies(copiesOf, to: &m.params.children[c]) { changed = true }
            op = .merge(m)
        }
        var setup = op.editableSetup
        let extra = setup.shapeIDs.flatMap { copiesOf[$0] ?? [] }.filter { !setup.shapeIDs.contains($0) }
        if !extra.isEmpty {
            setup.shapeIDs += extra
            op.editableSetup = setup
            TabAnchor.addCopies(copiesOf, to: &op)
            changed = true
        }
        return changed
    }
}

extension TabAnchor {
    /// Gives each copy of a vector the manual tabs of its original (same path, same fraction), so
    /// a nested or plated part is held like the one it was copied from instead of cut free.
    public static func addCopies(_ copiesOf: [UUID: [UUID]], to op: inout AnyOperation) {
        guard case .profile(var p) = op, let anchors = p.params.tabs.manualTabs else { return }
        let added = anchors.flatMap { a in
            (copiesOf[a.shapeID] ?? []).map { TabAnchor(shapeID: $0, pathIndex: a.pathIndex, fraction: a.fraction) }
        }.filter { !anchors.contains($0) }
        guard !added.isEmpty else { return }
        p.params.tabs.manualTabs = anchors + added
        op = .profile(p)
    }
}

private extension Rect2 {
    func translated(by v: Vec2) -> Rect2 { Rect2(min: min + v, max: max + v) }
}
