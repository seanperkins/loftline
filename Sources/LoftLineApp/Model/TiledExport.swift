import CADCore
import CAMCore
import Foundation
import PostCore

/// Toolpaths > Save Tiled G-code…: one program per tile for jobs larger than the machine.
enum TiledExport {
    /// Default tile = the post profile's X/Y travel in document units.
    static func defaultSettings(profile: PostProfile, units: LengthUnit) -> TilingSettings {
        let f = profile.units.factor(to: units)
        return TilingSettings(tileWidth: profile.limits.xTravel * f, tileHeight: profile.limits.yTravel * f, overlap: 0)
    }

    struct File {
        var tile: ToolpathTile
        var fileName: String
        var title: String
        var result: GCodeExportResult
    }

    /// Posts and validates every tile that has something to cut. `extraIssues` (the document's post, machine and tool
    /// notices, as the other exports show them) go first in every tile's issues.
    static func files(project: LoftLineProject, results: [UUID: ToolpathResult], profile: PostProfile,
                      groupByTool: Bool, settings: TilingSettings, extraIssues: [GCodeIssue] = []) -> [File] {
        let doc = project.document
        let all = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: groupByTool)
        let tiles = ToolpathTiling.tile(all, job: doc.job, units: doc.units, settings: settings)
        let total = tiles.count
        let base = GCodeExporter.suggestedFileName(jobName: doc.name, operationName: nil, profile: profile)
        let stem = (base as NSString).deletingPathExtension
        let missing = GCodeExporter.missingOperationIssues(project.operations, results: results)
        var probing = false
        if case .on? = profile.toolChangeProbe { probing = true }
        return tiles.filter { !$0.toolpaths.isEmpty }.map { tile in
            let at = "X\(RulerTicks.label(round4(tile.region.min.x))) Y\(RulerTicks.label(round4(tile.region.min.y)))"
            let title = "\(doc.name) tile \(tile.number) of \(total) - zero XY at material \(at)"
            // The tile's own project: its job, and the design moved into the tile frame so
            // material and keep-out checks line up with the clipped toolpaths.
            var p = project
            p.document.job = tile.job
            p.document.shapes = doc.shapes.map { $0.transformed(.translation(-tile.region.min)) }
            p.document.keepOutZones = doc.keepOutZones?.map { z in
                var moved = z
                moved.outline = z.outline.map { $0 - tile.region.min }
                return moved
            }
            // The touch-off spot is not defined per tile yet: no tile can be posted with touch-plate tool changes.
            var r = probing
                ? GCodeExporter.refused("Tiled jobs cannot be posted with touch-plate tool changes yet: the touch-off spot is not "
                                        + "defined per tile. Switch probing off in Preferences > Machines to post the tiles.",
                                        toolpathCount: tile.toolpaths.count)
                : GCodeExporter.export(project: p, toolpaths: tile.toolpaths, profile: profile, jobName: title)
            r.issues.insert(contentsOf: extraIssues + missing, at: 0)
            let name = String(format: "%@_tile%02d.%@", stem, tile.number, GCodeExporter.fileExtension(for: profile))
            return File(tile: tile, fileName: name, title: title, result: r)
        }
    }

    private static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
