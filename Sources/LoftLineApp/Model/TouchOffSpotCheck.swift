import CADCore
import CAMCore
import Foundation
import PostCore

/// The toolpaths a probed export checks the touch-off spot against: every operation of the sheet being posted, switched
/// on or off (a pocket cut earlier and then switched off is still a pocket), or why they cannot be had.
enum SheetToolpaths {
    case ready([Toolpath])
    case refused(String)
}

/// Where the touch plate lies at each tool change must be solid material: on the stock, off every keep-out zone and
/// clamp, and never where a toolpath of the sheet removes material, or the plate rests in a pocket and Z is set low by its
/// depth (spec §5).
enum TouchOffSpotCheck {
    /// A polygon that contains the disc of `radius` around `spot` (its sides touch the circle).
    static func footprint(spot: Vec2, radius: Double, sides: Int = 32) -> [Vec2] {
        let r = radius / cos(Double.pi / Double(sides))
        return (0..<sides).map { i in
            let a = 2 * Double.pi * Double(i) / Double(sides)
            return spot + Vec2(cos(a), sin(a)) * r
        }
    }

    /// Why the spot cannot take the plate, or nil. `project` is the export's (its job is the posted sheet's); `probe` is
    /// in `postUnits`. A job with no spot is left to the builder, which refuses it.
    static func problem(project: LoftLineProject, sheet: [Toolpath], probe: ToolChangeProbe, postUnits: LengthUnit) -> String? {
        let doc = project.document
        guard let spot = doc.job.touchOffSpot else { return nil }
        let size = probe.plateSize * postUnits.factor(to: doc.units)
        let plate = footprint(spot: spot, radius: size)
        let sizeText = "\(RulerTicks.label((size * 1000).rounded() / 1000)) \(doc.units.abbreviation)"
        let bounds = doc.job.materialBounds
        if !plate.allSatisfy({ $0.x >= bounds.min.x && $0.x <= bounds.max.x && $0.y >= bounds.min.y && $0.y <= bounds.max.y }) {
            return "The touch plate at the touch-off spot would hang over the edge of the material: keep the spot at least "
                + "\(sizeText) (the plate's size) from every edge."
        }
        let zones = (doc.keepOutZones ?? []).map { (name: $0.name, loops: [$0.outline]) }
            + Fixtures.zones(in: doc).map { (name: $0.name, loops: $0.loops) }
        for zone in zones {
            let overlap = GeomKernel.boolean(.intersection, subject: [plate], clip: zone.loops, fillRule: .evenOdd)
            if !overlap.isEmpty {
                return "The touch plate at the touch-off spot would lie on \"\(zone.name)\" (a keep-out zone or clamp): move the spot."
            }
        }
        let plateZone = Fixtures.Zone(name: "touch plate", loops: [plate], height: 0)
        let hits = LayoutChecks.keepOut(sheet, zones: [plateZone], job: doc.job, units: doc.units)
        if let first = hits.first, let name = sheet.first(where: { first.message.contains("'\($0.name)'") })?.name {
            return "\(name) cuts where the touch plate lies at the touch-off spot: the plate would rest in its cut and set Z "
                + "low. Move the spot onto material no toolpath on this sheet removes."
        } else if !hits.isEmpty {
            return "A toolpath on this sheet cuts where the touch plate lies at the touch-off spot: move the spot onto material "
                + "no toolpath removes."
        }
        return nil
    }
}

extension GCodeExporter {
    /// The sheet whose job a scope is posted with: a single toolpath's own sheet, else the sheet on screen.
    static func postedSheetID(project: LoftLineProject, scope: GCodeExportScope) -> UUID? {
        if case .operation(let id) = scope, let op = project.operations.first(where: { $0.id == id }) {
            return project.sheetID(of: op)
        }
        return project.document.currentSheetID
    }

    /// Every operation of `sheetID`, switched on or off.
    static func sheetOperations(project: LoftLineProject, sheetID: UUID?) -> [AnyOperation] {
        project.operations.filter { project.sheetID(of: $0) == sheetID }
    }

    /// Every toolpath of the sheet, from `project` as a whole (not an export's reduced copy) and the calculated results.
    static func sheetToolpaths(project: LoftLineProject, results: [UUID: ToolpathResult], sheetID: UUID?) -> SheetToolpaths {
        var out: [Toolpath] = []
        for op in sheetOperations(project: project, sheetID: sheetID) {
            guard let r = results[op.id] else {
                return .refused("\(op.setup.name) is not calculated: every toolpath on the sheet is checked against the "
                                + "touch-off spot before posting with the touch plate.")
            }
            if let e = r.error {
                // A switched-off toolpath that does not calculate removes no material; a switched-on one is a step missing.
                if op.setup.isEnabled { return .refused("\(op.setup.name) did not calculate (\(e)): the touch-off spot cannot be checked against it.") }
                continue
            }
            out += r.toolpaths
        }
        return .ready(out)
    }

    /// The sheet's toolpaths when `profile` probes, else nil (nothing to check).
    static func sheetToolpathsIfProbing(project: LoftLineProject, results: [UUID: ToolpathResult], scope: GCodeExportScope,
                                        profile: PostProfile) -> SheetToolpaths? {
        guard case .on? = profile.toolChangeProbe else { return nil }
        return sheetToolpaths(project: project, results: results, sheetID: postedSheetID(project: project, scope: scope))
    }

    /// What to calculate before posting: the exported operations, and with probing every operation of the posted sheet.
    /// The missing-from-the-program errors still judge only `exported`.
    static func calculationTargets(project: LoftLineProject, exported: [UUID], scope: GCodeExportScope,
                                   profile: PostProfile) -> [UUID] {
        guard case .on? = profile.toolChangeProbe else { return exported }
        let sheet = sheetOperations(project: project, sheetID: postedSheetID(project: project, scope: scope)).map(\.id)
        return exported + sheet.filter { !exported.contains($0) }
    }

    /// Why a probed export cannot check its touch-off spot, or nil.
    static func spotProblem(project: LoftLineProject, exported: [Toolpath], sheet: SheetToolpaths?, profile: PostProfile) -> String? {
        guard case .on(let probe)? = profile.toolChangeProbe else { return nil }
        switch sheet {
        case nil:
            return "Touch-plate tool changes need every toolpath on the sheet to check the touch-off spot, and this export has none."
        case .refused(let m)?:
            return m
        case .ready(let tps)?:
            let ids = Set(tps.map(\.id))
            guard exported.allSatisfy({ ids.contains($0.id) }) else {
                return "The toolpaths being exported are not among the sheet's toolpaths, so the touch-off spot cannot be checked."
            }
            return TouchOffSpotCheck.problem(project: project, sheet: tps, probe: probe, postUnits: profile.units)
        }
    }
}
