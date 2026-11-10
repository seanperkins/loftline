import CADCore
import CAMCore
import Foundation
import LoftLineKit
import PostCore

/// check, post_gcode, job_sheet (MCP spec, "The tools" and "Safety").
enum OutputTools {
    static let safety = "LoftLine checks every program as the app does and never writes one with an error. Show the user the summary "
        + "and the job sheet; they check the program and do an air cut before cutting."

    static func contextSchema() -> [String: [String: Any]] {
        ["post_id": Schema.string("A post from list_library; the project's own post when left out."),
         "group_by_tool": Schema.boolean("Order the program by tool, fewest tool changes."),
         "side": Schema.string("For a two-sided job: the side to post; the side on show when left out.", oneOf: ["top", "bottom"])]
    }

    static func context(_ args: Args) throws -> PostingContext {
        var side: JobSide?
        if let word = args.string("side") {
            guard let s = JobSide(rawValue: word) else { throw ToolError("\"side\" is top or bottom.") }
            side = s
        }
        return PostingContext(postID: args.string("post_id"), groupByTool: args.bool("group_by_tool"), side: side)
    }

    static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        let session = service.session

        let check = AssistantTool(
            name: "check",
            description: "What Toolpaths > Check Toolpaths reports for a post: errors, warnings and layout findings, by toolpath. Writes nothing. " + safety,
            inputSchema: Schema.object(contextSchema())) { raw in
                let report = try session.checkReport(context: try context(Args(raw)))
                let sections = report.sections.filter { !$0.issues.isEmpty }.map { s -> [String: Any] in
                    ["title": s.title, "issues": s.issues.map { ["severity": $0.severity == .error ? "error" : "warning", "message": $0.message] }]
                }
                let lines = report.sections.flatMap { s in s.issues.map { "\($0.severity == .error ? "error" : "warning"): \(s.title): \($0.message)" } }
                let head = report.isClean ? "No problems found." : "\(report.errorCount) error\(report.errorCount == 1 ? "" : "s"), "
                    + "\(report.warningCount) warning\(report.warningCount == 1 ? "" : "s")."
                return Reply.output(([head] + lines).joined(separator: "\n"), ["sections": sections])
            }

        var postProperties = contextSchema()
        postProperties["folder"] = Schema.string("An allowed folder to write the program(s) into.")
        postProperties["mode"] = Schema.string("one_file: the whole job; per_toolpath or per_tool: Save All's files; toolpath: one toolpath.",
                                               oneOf: ["one_file", "per_toolpath", "per_tool", "toolpath"])
        postProperties["toolpath_id"] = Schema.string("mode toolpath: the toolpath.")
        postProperties["replace"] = Schema.boolean("Overwrite files already there.")
        postProperties["job_sheet"] = Schema.boolean("Write the job sheet beside the program (default true).")
        let postGCode = AssistantTool(
            name: "post_gcode",
            description: "Posts G-code into an allowed folder with the job sheet beside it, all files or none. " + safety,
            inputSchema: Schema.object(postProperties, required: ["folder", "mode"])) { raw in
                let args = Args(raw)
                let ctx = try context(args)
                let folder = try access.resolve(try args.requireString("folder"))
                var posted: [(fileName: String, title: String, result: GCodeExportResult)]
                var scope = GCodeExportScope.all
                let profile = try session.profile(postID: ctx.postID)
                switch try args.requireString("mode") {
                case "one_file": posted = try session.postAll(mode: .oneFile, context: ctx).map { ($0.file.fileName, $0.file.title, $0.result) }
                case "per_toolpath": posted = try session.postAll(mode: .filePerToolpath, context: ctx).map { ($0.file.fileName, $0.file.title, $0.result) }
                case "per_tool": posted = try session.postAll(mode: .filePerTool, context: ctx).map { ($0.file.fileName, $0.file.title, $0.result) }
                case "toolpath":
                    guard let id = try args.uuid("toolpath_id"), let op = session.project.operations.first(where: { $0.id == id }) else {
                        throw ToolError("mode toolpath needs the toolpath_id of a toolpath in this project.")
                    }
                    let (r, p) = try session.post(scope: .operation(id), postID: ctx.postID, side: ctx.side, groupByTool: ctx.groupByTool)
                    let name = GCodeExporter.suggestedFileName(jobName: session.project.document.name, operationName: op.setup.name, profile: p)
                    posted = [(name, op.setup.name, r)]
                    scope = .operation(id)
                case let other: throw ToolError("Unknown mode \"\(other)\".")
                }
                // Nothing is written with an error, a missing step, or a file that didn't post.
                var problems: [String] = []
                guard !posted.isEmpty else { throw ToolError("Nothing to post: no calculated toolpaths are enabled.") }
                for (_, title, r) in posted {
                    if let e = r.errorMessage { problems.append("\(title): \(e)") }
                    problems += r.issues.filter { $0.severity == .error }.map { "\(title): \($0.message)" }
                    problems += r.missingSteps.map { "\(title): \($0.message)" }
                }
                guard problems.isEmpty else {
                    throw ToolError("Nothing was written. LoftLine found \(problems.count) error\(problems.count == 1 ? "" : "s"):\n"
                        + Array(NSOrderedSet(array: problems)).compactMap { $0 as? String }.joined(separator: "\n"))
                }
                var files = posted.map { GCodeFileSet.File(fileName: $0.fileName, title: $0.title, text: $0.result.fileText) }
                // The sheet and the summary describe the program written: one toolpath posted alone gets its own sheet.
                let sheet = try session.jobSheet(context: ctx, scope: scope)
                var sheetName: String?
                if args.raw["job_sheet"] == nil || args.bool("job_sheet") {
                    let name = GCodeExporter.fileSafeName(session.project.document.name.isEmpty ? "Untitled" : session.project.document.name)
                        + " job sheet.html"
                    files.append(GCodeFileSet.File(fileName: name, title: "the job sheet", text: JobSheetHTML.render(sheet)))
                    sheetName = name
                }
                let written = try AssistantWriter.write(files, into: folder, replace: args.bool("replace"), access: access)
                let warnings = posted.flatMap { $0.result.issues.filter { $0.severity == .warning }.map(\.message) }
                let resolved = session.resolved
                let summary = [
                    "Posted \(posted.count) program\(posted.count == 1 ? "" : "s") into \(folder.path). Check before cutting:",
                    "Machine: \(resolved.machine?.name ?? "none set")",
                    "Post: \(profile.name)",
                    "Units: \(session.project.document.units.abbreviation)",
                    "Material: \(sheet.material)",
                    "Z zero: \(sheet.zZeroInstruction)",
                    "XY origin: \(sheet.xyOriginInstruction)",
                    "Deepest cut: \(sheet.deepestCut.isEmpty ? "—" : sheet.deepestCut)",
                    "Time: \(sheet.totalTime)",
                    "Tool changes: \(sheet.toolChanges)",
                    "Pauses: \(sheet.pauses)",
                    sheetName.map { "Job sheet: \(folder.appendingPathComponent($0).path)" } ?? "Job sheet: not written",
                    "Show these to the user: they check the program and the job sheet, and do an air cut before cutting.",
                ]
                return Reply.output(summary.joined(separator: "\n"), ["files": written.map(\.path), "warnings": warnings])
            }

        var sheetProperties = contextSchema()
        sheetProperties["path"] = Schema.string("Where to write the job sheet (.html) in an allowed folder.")
        sheetProperties["replace"] = Schema.boolean("Overwrite a file already there.")
        let jobSheet = AssistantTool(
            name: "job_sheet",
            description: "Writes the job sheet (setup, clamps and screws, tools, toolpath order, pictures) for the program a post would make.",
            inputSchema: Schema.object(sheetProperties, required: ["path"])) { raw in
                let args = Args(raw)
                var url = try access.resolve(try args.requireString("path"))
                if url.pathExtension.lowercased() != "html" { url.appendPathExtension("html") }
                let html = try session.jobSheetHTML(context: try context(args))
                try AssistantWriter.write([GCodeFileSet.File(fileName: url.lastPathComponent, title: "the job sheet", text: html)],
                                          into: url.deletingLastPathComponent(), replace: args.bool("replace"), access: access)
                return Reply.output("Wrote the job sheet to \(url.path).")
            }

        return [check, postGCode, jobSheet]
    }
}
