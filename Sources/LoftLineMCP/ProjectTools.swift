import CADCore
import CAMCore
import Foundation
import LoftLineKit
import PostCore

/// new_project, open_project, save_project, describe_project, undo (MCP spec, "The tools").
enum ProjectTools {
    static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        let session = service.session
        let core = CoreClient(service: service)

        func refuseUnsaved(_ args: Args) throws {
            guard session.isDirty, !args.bool("discard") else { return }
            throw ToolError("The open project has unsaved changes. Save it with save_project, or pass discard: true to drop them.")
        }

        let newProject = AssistantTool(
            name: "new_project",
            description: "Starts a new, empty LoftLine project with its material size. Refuses while the open project has unsaved changes, unless discard is true.",
            inputSchema: Schema.object([
                "units": Schema.string("Units for the whole project.", oneOf: ["inch", "millimeter"]),
                "width": Schema.number("Material width (X) in those units."),
                "height": Schema.number("Material height (Y) in those units."),
                "thickness": Schema.number("Material thickness in those units."),
                "name": Schema.string("The job's name, used for file names."),
                "discard": Schema.boolean("Drop the open project's unsaved changes."),
            ], required: ["units", "width", "height", "thickness"])) { raw in
                let args = Args(raw)
                try refuseUnsaved(args)
                guard let units = LengthUnit(word: try args.requireString("units")) else { throw ToolError("\"units\" is inch or millimeter.") }
                var form = JobSetupForm(project: LoftLineProject(document: Document()), machines: session.machines, profiles: session.profiles)
                if units != form.units { form.setUnits(units) }
                form.job.width = try args.requireDouble("width")
                form.job.height = try args.requireDouble("height")
                form.job.thickness = try args.requireDouble("thickness")
                if let name = args.string("name") { form.name = name }
                guard form.problems.isEmpty else { throw ToolError(form.problems.joined(separator: " ")) }
                session.newProject()
                session.perform("Job Setup") { $0 = form.apply(to: $0) }
                let job = session.project.document.job
                return Reply.output("New project \"\(session.project.document.name)\": \(JobSheet.fmt(job.width, units)) x "
                    + "\(JobSheet.fmt(job.height, units)) x \(JobSheet.fmt(job.thickness, units)). Not saved yet.")
            }

        let openProject = AssistantTool(
            name: "open_project",
            description: "Opens a .loftline project from an allowed folder. Refuses while the open project has unsaved changes, unless discard is true.",
            inputSchema: Schema.object([
                "path": Schema.string("The .loftline file."),
                "discard": Schema.boolean("Drop the open project's unsaved changes."),
            ], required: ["path"])) { raw in
                let args = Args(raw)
                try refuseUnsaved(args)
                let url = try access.resolve(try args.requireString("path"))
                try core.call("open", ["path": url.path])
                return Reply.output("Opened \(url.lastPathComponent): \(summaryLine(session)).")
            }

        let saveProject = AssistantTool(
            name: "save_project",
            description: "Saves the project, to its own file or to a new .loftline path in an allowed folder. An existing file other than its own is replaced only with replace: true. "
                + "On a document open in LoftLine, its own file must be in an allowed folder, and a new path works only in the desktop app (on the Mac, Save As is the user's).",
            inputSchema: Schema.object([
                "path": Schema.string("Where to save; leave out to save to the project's own file. \".loftline\" is added when missing."),
                "replace": Schema.boolean("Overwrite a file already at that path."),
            ])) { raw in
                let args = Args(raw)
                var url: URL
                if let path = args.string("path") {
                    url = try access.resolve(path)
                } else if let own = session.fileURL {
                    url = try access.resolve(own.path)
                } else {
                    throw ToolError("This project has never been saved: give a path.")
                }
                if url.pathExtension.lowercased() != "loftline" { url.appendPathExtension("loftline") }
                let own = session.fileURL.map { (try? access.resolve($0.path))?.standardizedFileURL } ?? nil
                let isOwn = own == url.standardizedFileURL
                try session.save(to: url) { data, to in
                    let file = GCodeFileSet.File(fileName: to.lastPathComponent, title: "the project",
                                                 text: String(decoding: data, as: UTF8.self))
                    try AssistantWriter.write([file], into: to.deletingLastPathComponent(), replace: args.bool("replace"), access: access,
                                              alwaysReplaceable: isOwn ? [to.lastPathComponent] : [])
                }
                return Reply.output("Saved \(url.path).")
            }

        let describeProject = AssistantTool(
            name: "describe_project",
            description: "Describes the open project: job setup, post and machine, layers, shapes (with ids and bounds), toolpaths, "
                + "and every clamp and screw by the name and position the job sheet prints. Shapes are listed limit at a time from offset.",
            inputSchema: Schema.object([
                "limit": Schema.integer("Most shapes to list (default 200)."),
                "offset": Schema.integer("Shapes to skip (default 0)."),
            ])) { raw in
                let args = Args(raw)
                return Reply.output(summaryLine(session) + ".", describe(session, limit: max(1, args.int("limit") ?? 200),
                                                                         offset: max(0, args.int("offset") ?? 0)))
            }

        let undo = AssistantTool(
            name: "undo",
            description: "Takes back the last change to the project. On a document open in LoftLine, undo is the user's: Edit ▸ Undo there.",
            inputSchema: Schema.object([:])) { _ in
                guard let action = session.undoAction else { throw ToolError("There is nothing to undo.") }
                session.undo()
                return Reply.output("Undid \(action).")
            }

        return [newProject, openProject, saveProject, describeProject, undo]
    }

    static func summaryLine(_ s: CoreSession) -> String {
        let doc = s.project.document, u = doc.units
        return "\"\(doc.name)\", \(JobSheet.fmt(doc.job.width, u)) x \(JobSheet.fmt(doc.job.height, u)) x \(JobSheet.fmt(doc.job.thickness, u)), "
            + "\(doc.shapes.count) shape\(doc.shapes.count == 1 ? "" : "s"), \(s.project.operations.count) toolpath\(s.project.operations.count == 1 ? "" : "s")"
            + (s.isDirty ? ", unsaved changes" : "")
    }

    static func describe(_ s: CoreSession, limit: Int, offset: Int) -> [String: Any] {
        let project = s.project, doc = project.document, u = doc.units
        let job = doc.job
        let layersByID = Dictionary(doc.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shapes = doc.shapes.dropFirst(offset).prefix(limit).map { shape -> [String: Any] in
            let b = shape.bounds()
            return ["id": shape.id.uuidString, "name": shape.name, "layer": layersByID[shape.layerID]?.name ?? "",
                    "closed": shape.isClosed, "bounds": ["x": b.min.x, "y": b.min.y, "width": b.width, "height": b.height]]
        }
        let settings = TimeEstimateSettings.load()
        let toolpaths = project.operations.map { op -> [String: Any] in
            var row: [String: Any] = ["id": op.id.uuidString, "name": op.setup.name, "kind": op.kind.rawValue,
                                      "enabled": op.setup.isEnabled, "calculated": s.results[op.id] != nil, "stale": s.isStale(op.id)]
            if let tool = project.mergedTools(with: s.library).tool(id: op.setup.toolID) { row["tool"] = "T\(tool.number) \(tool.name)" }
            if let r = s.results[op.id] {
                if let e = r.error { row["error"] = e }
                row["time"] = ToolpathCalculator.formatDuration(settings.estimate(r.toolpaths, rapidRate: s.rapidRate, units: u, toolChanges: false))
            }
            return row
        }
        let clamps = ClampList.items(in: doc).map { item -> [String: Any] in
            ["name": item.name, "position": ClampList.position(of: item, job: job, units: u), "height": ClampList.heightText(of: item, units: u)]
        }
        let resolved = s.resolved
        var out: [String: Any] = [
            "name": doc.name, "unsaved": s.isDirty, "units": u.rawValue,
            "job": ["width": job.width, "height": job.height, "thickness": job.thickness, "zZero": job.zZero.rawValue,
                    "xyOrigin": job.xyOrigin.rawValue, "safeZ": job.safeZ, "twoSided": job.isTwoSided],
            "post": ["id": resolved.post.id, "name": resolved.post.name],
            "layers": doc.layers.map { l -> [String: Any] in
                var row: [String: Any] = ["id": l.id.uuidString, "name": l.name, "visible": l.isVisible,
                                          "shapes": doc.shapes.filter { $0.layerID == l.id }.count]
                if let k = l.keepOut { row["clampHeight"] = k.height }
                return row
            },
            "shapes": Array(shapes), "toolpaths": toolpaths, "clamps": clamps,
        ]
        if let path = s.fileURL?.path { out["path"] = path }
        if let machine = resolved.machine?.name { out["machine"] = machine }
        let more = doc.shapes.count - offset - shapes.count
        if more > 0 { out["moreShapes"] = more }
        return out
    }
}
