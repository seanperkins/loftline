import CADCore
import CAMCore
import Foundation
import PostCore

/// What a program is posted with: the post, tool grouping and side (nil = the project's own post and the side shown). One
/// context gives the program, its job sheet and its check report, so all three describe the same program (MCP spec).
public struct PostingContext: Equatable {
    public var postID: String?
    public var groupByTool: Bool
    public var side: JobSide?

    public init(postID: String? = nil, groupByTool: Bool = false, side: JobSide? = nil) {
        self.postID = postID; self.groupByTool = groupByTool; self.side = side
    }
}

extension CoreSession {
    /// The project as one side posts it, or as one toolpath posts alone (its own sheet's and side's job).
    func outputProject(scope: GCodeExportScope = .all, side: JobSide?) -> LoftLineProject {
        project.exportProject(for: scope, side: side ?? activeSide)
    }

    /// Calculates what the program and its checks read, as the Mac's Save All and Check Toolpaths do: the exported toolpaths,
    /// and with a touch-plate post every toolpath of the sheet, switched on or off, and a rest pass's source
    /// (`GCodeExporter.calculationTargets`). A stale result never feeds the touch-off check.
    func calculateForPosting(_ output: LoftLineProject, scope: GCodeExportScope, profile: PostProfile) {
        let exported = output.operations.filter { if case .operation = scope { return true }; return $0.setup.isEnabled }.map(\.id)
        calculateStale(GCodeExporter.calculationTargets(project: project, exported: exported, scope: scope, profile: profile))
    }

    /// The post's rapid rate in the document's units (`rapidRate` is the project's own post's).
    func rapidRate(of profile: PostProfile) -> Double { profile.rapidRate * profile.units.factor(to: project.document.units) }

    /// Save All's files, posted as the Mac's Save All posts them: a touch-plate post checks the spot against every toolpath on
    /// the sheet, and a project whose own post is not installed gets that error rather than the fallback post's program.
    public func postAll(mode: SaveAllMode, context: PostingContext) throws -> [(file: PlannedGCodeFile, result: GCodeExportResult)] {
        let profile = try profile(postID: context.postID)
        let output = outputProject(side: context.side)
        calculateForPosting(output, scope: .all, profile: profile)
        let files = GCodeBatchExport.plan(mode: mode, operations: output.operations, results: results, jobName: project.document.name,
                                          profile: profile, groupByTool: context.groupByTool)
        let sheet = GCodeExporter.sheetToolpathsIfProbing(project: project, results: results, scope: .all, profile: profile)
        let posted = GCodeBatchExport.post(files, project: output, profile: profile, jobName: project.document.name,
                                           expected: .operations(output.operations.filter(\.setup.isEnabled), results: results),
                                           sheetToolpaths: sheet)
        let issues = postIssues(for: profile)
        guard !issues.isEmpty else { return posted }
        return posted.map { item in
            var r = item.result
            r.issues.insert(contentsOf: issues, at: 0)
            return (item.file, r)
        }
    }

    /// The job sheet for the program this context posts: its post, its step order and tool changes, its side.
    public func jobSheetHTML(context: PostingContext) throws -> String { JobSheetHTML.render(try jobSheet(context: context)) }

    /// The job sheet's model (material, Z zero, deepest cut, times, tool changes, pauses) for this context; with an operation
    /// scope, for that toolpath posted alone, with its own sheet's and side's job.
    public func jobSheet(context: PostingContext, scope: GCodeExportScope = .all) throws -> JobSheet {
        let profile = try profile(postID: context.postID)
        let output = outputProject(scope: scope, side: context.side)
        calculateForPosting(output, scope: scope, profile: profile)
        var sheet = JobSheet.make(project: output, results: results, profile: profile, groupByTool: context.groupByTool,
                                  rapidRate: rapidRate(of: profile), sheets: JobSheet.sheets(of: project),
                                  settings: TimeEstimateSettings.load())
        // As the Mac's: which material sheet and side this sheet is for.
        let doc = project.document
        sheet.jobName = doc.name + (doc.isMultiSheet ? " – \(doc.currentSheetName)" : "")
            + (doc.job.isTwoSided ? " (\(sideShown(scope: scope, context: context).displayName) side)" : "")
        return sheet
    }

    /// What Toolpaths > Check Toolpaths… reports for this context, with the project's post problems first.
    public func checkReport(context: PostingContext) throws -> ValidationReport {
        let profile = try profile(postID: context.postID)
        let output = outputProject(side: context.side)
        calculateForPosting(output, scope: .all, profile: profile)
        let sheet = GCodeExporter.sheetToolpathsIfProbing(project: project, results: results, scope: .all, profile: profile)
        var report = ValidationReport.make(project: output, results: results, profile: profile, groupByTool: context.groupByTool,
                                           sheetToolpaths: sheet)
        let issues = postIssues(for: profile)
        if !issues.isEmpty {
            report.sections.insert(ValidationReport.Section(id: "post", title: "Post", operationID: nil, issues: issues), at: 0)
        }
        return report
    }

    /// The side a sheet is for: a toolpath posted alone is on its own side.
    func sideShown(scope: GCodeExportScope, context: PostingContext) -> JobSide {
        if case .operation(let id) = scope, let op = project.operations.first(where: { $0.id == id }), let side = project.side(of: op) { return side }
        return context.side ?? activeSide
    }

    /// The project's post problems ("is not installed", copies that differ), as `post` adds them.
    func postIssues(for profile: PostProfile) -> [GCodeIssue] {
        ProjectPost.issues(for: project, profiles: profiles, machines: machines, includingPost: profile.id == resolved.post.id)
    }
}
