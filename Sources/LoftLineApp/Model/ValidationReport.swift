import CADCore
import CAMCore
import Foundation
import PostCore

/// Validator results for the whole job, one section per toolpath plus the combined program
/// (problems that only appear between toolpaths). Shown by Toolpaths > Check Toolpaths….
struct ValidationReport {
    struct Section: Identifiable {
        var id: String
        var title: String
        var operationID: UUID?
        var issues: [GCodeIssue]
    }

    var sections: [Section]

    var allIssues: [GCodeIssue] { sections.flatMap(\.issues) }
    var errorCount: Int { allIssues.filter { $0.severity == .error }.count }
    var warningCount: Int { allIssues.filter { $0.severity == .warning }.count }
    var isClean: Bool { allIssues.isEmpty }

    static func make(project: LoftLineProject, results: [UUID: ToolpathResult], profile: PostProfile,
                     groupByTool: Bool) -> ValidationReport {
        let jobName = project.document.name
        var sections: [Section] = []
        var seen = Set<String>()
        let layout = LayoutChecks.materialFits(project.document.job, units: project.document.units, profile: profile)
            + LayoutChecks.design(project.document, ignoredLayers: project.layoutIgnoredLayers)
        if !layout.isEmpty {
            sections.append(Section(id: "layout", title: "Material and machine", operationID: nil, issues: layout))
        }
        for op in project.operations where op.setup.isEnabled {
            var issues: [GCodeIssue] = []
            if let r = results[op.id] {
                if let e = r.error {
                    issues.append(GCodeIssue(severity: .warning, message: "Not exported — \(e)"))
                } else {
                    let ex = GCodeExporter.export(project: project, toolpaths: GCodeExporter.operationToolpaths(op, results: results),
                                                        profile: profile, jobName: jobName)
                    if let e = ex.errorMessage { issues.append(GCodeIssue(severity: .error, message: e)) }
                    issues += ex.issues
                }
            } else {
                issues.append(GCodeIssue(severity: .warning, message: "Not calculated yet"))
            }
            issues.forEach { seen.insert($0.message) }
            sections.append(Section(id: op.id.uuidString, title: op.setup.name, operationID: op.id, issues: issues))
        }
        let all = GCodeExporter.toolpaths(scope: .all, operations: project.operations, results: results,
                                          groupByTool: groupByTool)
        if !all.isEmpty {
            let ex = GCodeExporter.export(project: project, toolpaths: all, profile: profile, jobName: jobName)
            var extra = ex.issues.filter { !seen.contains($0.message) }
            if let e = ex.errorMessage { extra.insert(GCodeIssue(severity: .error, message: e), at: 0) }
            sections.append(Section(id: "combined", title: "Combined program", operationID: nil, issues: extra))
        }
        return ValidationReport(sections: sections)
    }
}
