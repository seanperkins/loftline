import CADCore
import CAMCore
import Foundation

/// Grid resolution for nesting (more cells = tighter packing, slower).
enum NestPrecision: String, CaseIterable, Identifiable {
    case draft, normal, fine
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var cells: Int {
        switch self {
        case .draft: return 250_000
        case .normal: return 1_000_000
        case .fine: return 3_000_000
        }
    }
}

/// Settings of Design > Nest Parts….
struct NestingOptions: Equatable {
    var spacing: Double
    var margin: Double
    /// Degrees; 0 = keep orientation.
    var rotationStep: Double = 90
    var nestInHoles = true
    /// Copies of every part (the originals count as the first copy).
    var quantity = 1
    var precision: NestPrecision = .normal
    /// Keep clear of vectors that are not being nested.
    var avoidOtherVectors = true
    /// Put parts that do not fit on the material onto extra sheets (layers "Sheet 2", …).
    var overflowSheets = false
    var maxSheets = 10

    static func defaults(for units: LengthUnit) -> NestingOptions {
        units == .inch ? NestingOptions(spacing: 0.375, margin: 0.25)
            : NestingOptions(spacing: 10, margin: 6)
    }

    func settings(for job: JobSetup, maxSheets: Int = 1) -> NestSettings {
        NestSettings(sheetWidth: job.width, sheetHeight: job.height, margin: max(0, margin),
                     spacing: max(0, spacing), rotationStep: rotationStep, nestInHoles: nestInHoles,
                     maxSheets: maxSheets, precision: precision.cells)
    }
}

/// Outcome of a nest, for the sheet's summary line.
struct NestingReport: Equatable {
    var parts: Int
    var placed: Int
    var unplaced: Int
    var sheets: Int
    var utilisation: [Double]
    /// Shapes of all placed parts (originals and new copies), for the new selection.
    var placedShapeIDs: [UUID]

    var summary: String {
        var s = "Placed \(placed) of \(placed + unplaced) part\(placed + unplaced == 1 ? "" : "s")"
        if sheets > 1 { s += " on \(sheets) sheets" }
        if !utilisation.isEmpty {
            s += " (" + utilisation.map { "\(Int(($0 * 100).rounded()))%" }.joined(separator: ", ") + " of the material used)"
        }
        if unplaced > 0 { s += ". \(unplaced) did not fit and \(unplaced == 1 ? "was" : "were") left where \(unplaced == 1 ? "it was" : "they were") (or not created)." }
        return s
    }
}

enum NestingCommands {
    /// Nests the given shapes (grouped into parts by `NestPartBuilder`) on the material.
    /// Copies beyond the first are new shapes and are added to every toolpath that uses the
    /// original. Parts that do not fit stay where they are.
    static func nest(_ ids: [UUID], options: NestingOptions, in project: inout LoftLineProject) -> NestingReport {
        // Nesting always fills sheet 1 first, so put it on the material.
        NestSheets.activate(1, in: &project.document)
        let doc = project.document
        let keepOut = Fixtures.keepOutLayerIDs(in: doc)
        let shapes = doc.shapes(ids: doc.expandToGroups(ids)).filter { project.isEditable($0) && !keepOut.contains($0.layerID) }
        let tol = doc.units == .inch ? 0.002 : 0.05
        let groups = NestPartBuilder.parts(from: shapes, tolerance: tol)
        guard !groups.isEmpty else {
            return NestingReport(parts: 0, placed: 0, unplaced: 0, sheets: 0, utilisation: [], placedShapeIDs: [])
        }
        let moving = Set(groups.flatMap(\.shapeIDs))
        var obstacles: [[Vec2]] = []
        if options.avoidOtherVectors {
            let onMaterial = NestSheets.activeDocument(doc)
            let others = onMaterial.shapes.filter { !moving.contains($0.id) && project.isVisible($0) }
            for s in others { obstacles += NestPartBuilder.parts(from: [s], tolerance: tol).flatMap(\.outline) }
        }
        let parts = groups.map { NestPart(outline: $0.outline, quantity: max(1, options.quantity)) }
        let sheets = options.overflowSheets ? max(1, options.maxSheets) : 1
        // Clamps and screws are on every sheet.
        let result = Nester.nest(parts, settings: options.settings(for: doc.job, maxSheets: sheets),
                                 obstacles: Fixtures.zones(in: doc).flatMap(\.loops), firstSheetObstacles: obstacles)
        return apply(result, groups: groups, in: &project)
    }

    /// Moves originals / creates copies according to `result`. Sheet 1 is the material; parts
    /// for sheet k ≥ 2 go to that sheet's layer, parked beside the material.
    static func apply(_ result: NestResult, groups: [NestPartGroup], in project: inout LoftLineProject) -> NestingReport {
        var placedIDs: [UUID] = []
        // Copies are made from the shapes as they were before any part moved.
        let before = Dictionary(uniqueKeysWithValues: project.document.shapes.map { ($0.id, $0) })
        let baseLayer = project.document.layers.first { $0.sheet == nil }?.id ?? project.document.defaultLayerID
        for pl in result.placements {
            let group = groups[pl.part]
            var t = pl.transform
            var layer: UUID?
            if pl.sheet > 0 {
                let n = pl.sheet + 1
                layer = NestSheets.ensureLayer(forSheet: n, in: &project.document)
                t = t.concatenating(.translation(NestSheets.offset(ofSheet: n, in: project.document)))
            }
            if pl.copy == 0 {
                let ids = Set(group.shapeIDs)
                project.transformShapes(ids, by: t)
                for i in project.document.shapes.indices where ids.contains(project.document.shapes[i].id) {
                    let onSheetLayer = project.document.layer(id: project.document.shapes[i].layerID)?.sheet != nil
                    if let l = layer {
                        project.document.shapes[i].layerID = l
                    } else if onSheetLayer {
                        project.document.shapes[i].layerID = baseLayer
                    }
                }
                placedIDs += group.shapeIDs
            } else {
                let originals = group.shapeIDs.compactMap { before[$0] }
                var groupMap: [UUID: UUID] = [:]
                var idMap: [UUID: UUID] = [:]
                for s in originals {
                    var c = s.transformed(t)
                    c.id = UUID()
                    // Every grouping level gets a new id, shared by this copy's shapes only.
                    func remap(_ g: UUID) -> UUID {
                        if let n = groupMap[g] { return n }
                        let n = UUID()
                        groupMap[g] = n
                        return n
                    }
                    c.groupID = s.groupID.map(remap)
                    c.innerGroupIDs = s.innerGroupIDs?.map(remap)
                    if let l = layer {
                        c.layerID = l
                    } else if project.document.layer(id: c.layerID)?.sheet != nil {
                        c.layerID = baseLayer
                    }
                    project.document.add(c)
                    idMap[s.id] = c.id
                    placedIDs.append(c.id)
                }
                addCopies(idMap, toOperationsOf: &project)
            }
        }
        NestSheets.removeEmptySheets(in: &project.document)
        return NestingReport(parts: groups.count, placed: result.placements.count, unplaced: result.unplacedCount,
                             sheets: result.sheetsUsed, utilisation: result.utilisation, placedShapeIDs: placedIDs)
    }

    /// Adds each copy next to its original in every operation that cuts the original.
    static func addCopies(_ idMap: [UUID: UUID], toOperationsOf project: inout LoftLineProject) {
        for i in project.operations.indices {
            var s = project.operations[i].editableSetup
            let extra = s.shapeIDs.compactMap { idMap[$0] }
            guard !extra.isEmpty else { continue }
            s.shapeIDs += extra
            project.operations[i].editableSetup = s
            TabAnchor.addCopies(idMap.mapValues { [$0] }, to: &project.operations[i])
        }
    }
}

extension LoftLineProject {
    /// Layers left out of the "vectors outside the material" check: sheets parked beside it.
    var layoutIgnoredLayers: Set<UUID> { NestSheets.parkedLayerIDs(in: document) }
}
