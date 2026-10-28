import CADCore
import CAMCore
import Foundation
import PostCore

/// Operator setup sheet: what to load, where to zero, which tools in which order. Pure model
/// built from the project and its calculated toolpaths; `JobSheetHTML` renders it for printing.
struct JobSheet: Equatable {
    struct ToolRow: Equatable {
        var number: Int
        var name: String
        var kind: String
        var diameter: String
        var rpm: String
        var feed: String
        var plunge: String
        var usedBy: [String]
    }

    struct Step: Equatable {
        var index: Int
        var name: String
        var kind: String
        var tool: String
        /// True when this step needs a different tool from the step before (a manual change).
        var toolChange: Bool
        var maxDepth: String
        var time: String
        var notes: [String]
        /// The operator pause the program makes after this step ("Flip the part"), or nil.
        var pauseAfter: String? = nil
    }

    /// One piece of material: its outline, the vectors on it and the parts list.
    struct Sheet: Equatable {
        var title: String
        /// Shapes moved into the material frame of this sheet.
        var shapes: [Shape]
        var partNames: [String]
        /// Where each part's name is printed on the preview (parallel to `partNames`).
        var partCentres: [Vec2] = []
    }

    var jobName: String
    var date: String
    var units: LengthUnit
    var material: String
    var zZeroInstruction: String
    var xyOriginInstruction: String
    var origin: Vec2
    var safeZ: String
    var home: String
    var postName: String
    var tools: [ToolRow]
    var steps: [Step]
    var totalTime: String
    var toolChanges: Int
    var warnings: [String]
    var sheets: [Sheet]
    var materialSize: Vec2
    var layerColors: [UUID: String]
    /// The document's job notes (io), printed under the setup table.
    var notes: String = ""
    /// Operator pauses in the program (steps with `pauseAfter`).
    var pauses: Int = 0
    /// The lowest cut of the whole job, as the Export sheet words it ("Z -0.77 in (0.02 in below the material bottom)"); empty with no toolpaths.
    var deepestCut: String = ""

    /// One entry per nesting sheet (shapes moved onto the material frame), or nil when the
    /// document has a single sheet.
    static func sheets(of project: LoftLineProject) -> [Sheet]? {
        let doc = project.document
        guard NestSheets.hasSheets(doc) else { return nil }
        let active = NestSheets.activeSheet(in: doc)
        return NestSheets.numbers(in: doc).map { n in
            let shapes = NestSheets.shapes(onSheet: n, in: doc).filter { project.isVisible($0) || n != active }
            let parts = partList(shapes, in: doc)
            return Sheet(title: "Sheet \(n)" + (n == active ? " (on the material now)" : ""), shapes: shapes,
                         partNames: parts.map(\.name), partCentres: parts.map(\.centre))
        }
    }

    /// Parts among `shapes` (labels and keep-out zones left out) with their names: the name of
    /// the part's largest shape, else "Part N".
    static func partList(_ shapes: [Shape], in doc: Document) -> [(name: String, centre: Vec2)] {
        let skip = Fixtures.keepOutLayerIDs(in: doc)
            .union(doc.layers.filter { $0.name == PartLabelCommands.layerName }.map(\.id))
        let candidates = shapes.filter { !skip.contains($0.layerID) }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return NestPartBuilder.parts(from: candidates).enumerated().map { i, part in
            let members = part.shapeIDs.compactMap { byID[$0] }
            let primary = members.max { $0.bounds().width * $0.bounds().height < $1.bounds().width * $1.bounds().height }
            let name = primary.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Part \(i + 1)"
            return (name, Rect2(points: part.outline.joined()).center)
        }
    }

    static func fmt(_ v: Double, _ units: LengthUnit) -> String {
        RulerTicks.label((v * 10000).rounded() / 10000) + " " + units.abbreviation
    }

    /// What an optional stop does on this post: M1 where the controller has the switch, M0 on GRBL, which has none (#115).
    static func stopNote(_ pause: PauseStep, profile: PostProfile) -> String {
        guard pause.isOptionalStop else { return "" }
        return profile.honoursOptionalStop ? " (optional stop, M1)" : " (stops, M0: GRBL has no optional stop)"
    }

    /// - Parameters:
    ///   - sheets: one entry per piece of material; nil = one sheet with every visible shape.
    ///   - settings: the user's time-estimate settings, so the total is the sidebar's and the preview's, and each
    ///     step's time is the same model applied to that toolpath alone.
    static func make(project: LoftLineProject, results: [UUID: ToolpathResult], profile: PostProfile,
                     groupByTool: Bool, rapidRate: Double, date: Date = Date(),
                     sheets: [Sheet]? = nil, settings: TimeEstimateSettings) -> JobSheet {
        let doc = project.document
        let job = doc.job
        let u = doc.units
        let coords = MachineCoordinates(job: job)

        let toolpaths = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                                groupByTool: groupByTool)
        var steps: [Step] = []
        var toolRows: [ToolRow] = []
        var lastTool: UUID?
        for (i, tp) in toolpaths.enumerated() {
            let t = tp.tool.converted(to: u)
            let depth = tp.minZ.map { coords.depth(ofMachineZ: $0) }
            var notes: [String] = []
            if let w = tp.metadata["warning"] { notes.append(w) }
            // A facing changes where the top of the material is for the steps after it.
            if tp.kind == .facing, let n = tp.metadata["note"] { notes.append(n) }
            // As in the post: no stop after the last toolpath, the program ends there.
            let pause = i + 1 < toolpaths.count ? tp.pauseAfter : nil
            steps.append(Step(index: steps.count + 1, name: tp.name, kind: tp.kind.displayName,
                              tool: JobSummary.label(tp.tool), toolChange: lastTool != tp.tool.id,
                              maxDepth: depth.map { fmt(max(0, $0), u) } ?? "—",
                              time: ToolpathCalculator.formatDuration(settings.estimate([tp], rapidRate: rapidRate, units: u, toolChanges: false)),
                              notes: notes,
                              pauseAfter: pause.map { $0.text(afterToolpath: tp.name) + Self.stopNote($0, profile: profile) }))
            lastTool = tp.tool.id
            if let i = toolRows.firstIndex(where: { $0.number == t.number && $0.name == t.name }) {
                if !toolRows[i].usedBy.contains(tp.name) { toolRows[i].usedBy.append(tp.name) }
            } else {
                toolRows.append(ToolRow(number: t.number, name: t.name, kind: t.kind.displayName,
                                        diameter: fmt(t.diameter, u) + (t.angle.map { ", \(RulerTicks.label($0))°" } ?? ""),
                                        rpm: "\(Int(tp.spindleRPM.rounded()))",
                                        feed: RulerTicks.label((t.feedRate * 10).rounded() / 10) + " \(u.abbreviation)/min",
                                        plunge: RulerTicks.label((t.plungeRate * 10).rounded() / 10) + " \(u.abbreviation)/min",
                                        usedBy: [tp.name]))
            }
        }

        var warnings = (LayoutChecks.materialFits(job, units: u, profile: profile)
            + LayoutChecks.design(doc, ignoredLayers: project.layoutIgnoredLayers)
            + PreflightChecks.issues(project: project, toolpaths: toolpaths, units: u)).map(\.message)
        for op in project.operations where op.setup.isEnabled {
            if let r = results[op.id] {
                if let e = r.error { warnings.append("\(op.setup.name): \(e)") }
            } else {
                warnings.append("\(op.setup.name): not calculated, so it is not on this sheet")
            }
        }

        let origin: String
        switch job.xyOrigin {
        case .lowerLeft: origin = "the lower-left corner"
        case .lowerRight: origin = "the lower-right corner"
        case .upperLeft: origin = "the upper-left corner"
        case .upperRight: origin = "the upper-right corner"
        case .center: origin = "the center"
        }
        let zText = job.zZero == .materialTop
            ? "Touch off Z0 on the TOP of the material (\(fmt(job.thickness, u)) thick)."
            : "Touch off Z0 on the SPOILBOARD (machine bed); the material top is Z \(fmt(job.thickness, u))."

        let visible = doc.shapes.filter { project.isVisible($0) }
        let defaultParts = partList(visible, in: doc)
        let defaultSheet = Sheet(title: "Sheet 1", shapes: visible, partNames: defaultParts.map(\.name),
                                 partCentres: defaultParts.map(\.centre))
        let total = settings.estimate(toolpaths, rapidRate: rapidRate, units: u)
        let deepest = toolpaths.compactMap(\.minZ).min().map { z -> String in
            let depth = coords.depth(ofMachineZ: z)
            return DeepestCut(machineZ: z, depthBelowTop: depth, belowBottom: depth - job.thickness).text(units: u)
        } ?? ""
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        return JobSheet(
            jobName: doc.name, date: df.string(from: date), units: u,
            material: "\(fmt(job.width, u)) x \(fmt(job.height, u)) x \(fmt(job.thickness, u)) thick",
            zZeroInstruction: zText,
            xyOriginInstruction: "Zero X and Y at \(origin) of the material.",
            origin: job.originInMaterialFrame,
            safeZ: fmt(job.safeZ, u) + " above the material",
            home: "X \(RulerTicks.label(job.home.x)) Y \(RulerTicks.label(job.home.y)), \(fmt(job.homeZ, u)) above the material",
            postName: profile.name, tools: toolRows, steps: steps,
            totalTime: ToolpathCalculator.formatDuration(total),
            toolChanges: max(0, JobSummary.sequence(of: toolpaths).count - 1),
            warnings: warnings, sheets: sheets ?? [defaultSheet],
            materialSize: Vec2(job.width, job.height),
            layerColors: Dictionary(uniqueKeysWithValues: doc.layers.map { ($0.id, $0.colorHex) }),
            notes: doc.jobNotes,
            pauses: steps.filter { $0.pauseAfter != nil }.count,
            deepestCut: deepest)
    }
}

/// Printable HTML for a `JobSheet` (opened in the browser, printed from there).
enum JobSheetHTML {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func render(_ js: JobSheet) -> String {
        let e = escape
        var h = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Job sheet: \(e(js.jobName))</title>
        <style>
        body{font:13px -apple-system,Helvetica,Arial,sans-serif;color:#111;margin:24px;}
        h1{font-size:20px;margin:0 0 4px} h2{font-size:15px;margin:22px 0 6px;border-bottom:1px solid #999}
        table{border-collapse:collapse;width:100%} th,td{border:1px solid #bbb;padding:4px 6px;text-align:left;vertical-align:top}
        th{background:#eee} .muted{color:#555} .change{font-weight:bold;color:#b00} .pause td{background:#fff3c4;font-weight:bold}
        .setup td:first-child{width:150px;font-weight:bold} .warn{color:#b35c00}
        svg{border:1px solid #888;background:#fafafa;max-width:100%;height:auto}
        .sheet{page-break-inside:avoid} input{margin-right:6px}
        @media print{body{margin:10mm}}
        </style></head><body>
        <h1>Job sheet: \(e(js.jobName))</h1>
        <div class="muted">\(e(js.date)) · Post: \(e(js.postName)) · Estimated time \(e(js.totalTime)) · \(js.toolChanges) tool change\(js.toolChanges == 1 ? "" : "s")\(js.pauses > 0 ? " · \(js.pauses) pause\(js.pauses == 1 ? "" : "s")" : "")</div>
        <h2>Setup</h2>
        <table class="setup">
        <tr><td>Material</td><td>\(e(js.material))</td></tr>
        <tr><td>Z zero</td><td>\(e(js.zZeroInstruction))</td></tr>
        <tr><td>XY origin</td><td>\(e(js.xyOriginInstruction))</td></tr>
        <tr><td>Safe Z</td><td>\(e(js.safeZ))</td></tr>
        <tr><td>Home</td><td>\(e(js.home))</td></tr>
        \(js.deepestCut.isEmpty ? "" : "<tr><td>Deepest cut</td><td>\(e(js.deepestCut))</td></tr>")
        </table>

        """
        if !js.notes.isEmpty {
            h += "<h2>Notes</h2><div style=\"white-space:pre-wrap\">\(e(js.notes))</div>\n"
        }
        if !js.warnings.isEmpty {
            h += "<h2>Warnings</h2><ul>" + js.warnings.map { "<li class=\"warn\">\(e($0))</li>" }.joined() + "</ul>\n"
        }
        h += "<h2>Tools</h2><table><tr><th>Tool</th><th>Type</th><th>Diameter</th><th>RPM</th><th>Feed</th><th>Plunge</th><th>Used by</th></tr>\n"
        for t in js.tools {
            h += "<tr><td>T\(t.number) \(e(t.name))</td><td>\(e(t.kind))</td><td>\(e(t.diameter))</td><td>\(e(t.rpm))</td><td>\(e(t.feed))</td><td>\(e(t.plunge))</td><td>\(e(t.usedBy.joined(separator: ", ")))</td></tr>\n"
        }
        h += "</table>\n<h2>Toolpath order</h2><table><tr><th>✓</th><th>#</th><th>Toolpath</th><th>Type</th><th>Tool</th><th>Max depth</th><th>Time</th></tr>\n"
        for s in js.steps {
            let tool = s.toolChange ? "<span class=\"change\">Load \(e(s.tool))</span>" : e(s.tool)
            let notes = s.notes.isEmpty ? "" : "<div class=\"warn\">" + s.notes.map(e).joined(separator: "<br>") + "</div>"
            h += "<tr><td><input type=\"checkbox\"></td><td>\(s.index)</td><td>\(e(s.name))\(notes)</td><td>\(e(s.kind))</td><td>\(tool)</td><td>\(e(s.maxDepth))</td><td>\(e(s.time))</td></tr>\n"
            if let p = s.pauseAfter {
                h += "<tr class=\"pause\"><td><input type=\"checkbox\"></td><td></td><td colspan=\"5\">Pause: \(e(p)) &mdash; the machine waits for Cycle Start</td></tr>\n"
            }
        }
        if js.steps.isEmpty { h += "<tr><td colspan=\"7\" class=\"muted\">No calculated toolpaths.</td></tr>\n" }
        h += "</table>\n"
        if js.steps.count > 1 {
            // The same model as the total, one toolpath at a time: the total plans the program as one run.
            h += "<p class=\"muted\">Each time is that toolpath timed on its own, from a standstill. The estimated total "
                + "times the whole program as one run (the moves between toolpaths, the tool-change allowance, the stops, "
                + "speed carried across a join), so it is not the sum of this column.</p>\n"
        }
        for sheet in js.sheets {
            h += "<div class=\"sheet\"><h2>\(e(sheet.title))</h2>\n" + preview(sheet, js) + "\n"
            if !sheet.partNames.isEmpty {
                h += "<p><b>Parts (\(sheet.partNames.count)):</b> " + sheet.partNames.map(e).joined(separator: ", ") + "</p>\n"
            }
            h += "</div>\n"
        }
        h += "</body></html>\n"
        return h
    }

    /// Material outline, vectors (flattened) and the XY origin marker, Y up.
    static func preview(_ sheet: JobSheet.Sheet, _ js: JobSheet) -> String {
        let w = max(js.materialSize.x, 1e-6), hgt = max(js.materialSize.y, 1e-6)
        let pad = max(w, hgt) * 0.04
        let stroke = max(w, hgt) / 600
        func pt(_ p: Vec2) -> String { "\(num(p.x)),\(num(hgt - p.y))" }
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"720\" viewBox=\"\(num(-pad)) \(num(-pad)) \(num(w + 2 * pad)) \(num(hgt + 2 * pad))\">"
        s += "<rect x=\"0\" y=\"0\" width=\"\(num(w))\" height=\"\(num(hgt))\" fill=\"#f3e7cf\" stroke=\"#555\" stroke-width=\"\(num(stroke * 2))\"/>"
        let tol = max(w, hgt) / 2000
        for shape in sheet.shapes {
            let color = js.layerColors[shape.layerID] ?? "#000000"
            for path in shape.paths {
                let pts = path.flattened(tolerance: tol)
                guard pts.count > 1 else { continue }
                let tag = path.isClosed ? "polygon" : "polyline"
                s += "<\(tag) points=\"\(pts.map(pt).joined(separator: " "))\" fill=\"none\" stroke=\"\(escape(color))\" stroke-width=\"\(num(stroke))\"/>"
            }
        }
        for (name, c) in zip(sheet.partNames, sheet.partCentres) {
            s += "<text x=\"\(num(c.x))\" y=\"\(num(hgt - c.y))\" font-size=\"\(num(pad * 0.45))\" text-anchor=\"middle\" fill=\"#335\">\(escape(name))</text>"
        }
        let o = js.origin, r = pad * 0.35
        s += "<circle cx=\"\(num(o.x))\" cy=\"\(num(hgt - o.y))\" r=\"\(num(r))\" fill=\"none\" stroke=\"#d00\" stroke-width=\"\(num(stroke * 2))\"/>"
        s += "<line x1=\"\(num(o.x - r * 1.6))\" y1=\"\(num(hgt - o.y))\" x2=\"\(num(o.x + r * 1.6))\" y2=\"\(num(hgt - o.y))\" stroke=\"#d00\" stroke-width=\"\(num(stroke * 2))\"/>"
        s += "<line x1=\"\(num(o.x))\" y1=\"\(num(hgt - o.y - r * 1.6))\" x2=\"\(num(o.x))\" y2=\"\(num(hgt - o.y + r * 1.6))\" stroke=\"#d00\" stroke-width=\"\(num(stroke * 2))\"/>"
        s += "<text x=\"\(num(o.x + r * 1.2))\" y=\"\(num(hgt - o.y - r * 1.2))\" font-size=\"\(num(pad * 0.6))\" fill=\"#d00\">X0 Y0</text>"
        s += "</svg>"
        return s
    }

    private static func num(_ v: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), v) }
}
