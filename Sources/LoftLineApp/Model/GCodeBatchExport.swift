import CADCore
import CAMCore
import Foundation
import PostCore

/// "Save All Toolpaths": how the enabled, calculated toolpaths are split into files.
enum SaveAllMode: String, CaseIterable, Identifiable {
    /// One program, toolpaths grouped so each tool is loaded once.
    case oneFileGroupedByTool
    /// One program in toolpath-list order (a tool change wherever the tool differs).
    case oneFileInOrder
    /// One program per toolpath (operation).
    case filePerToolpath
    /// One program per tool run, numbered in run order (no tool changes inside a file). A tool
    /// gets several files when its toolpaths cannot safely be run together.
    case filePerTool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneFileGroupedByTool: return "One file, grouped by tool"
        case .oneFileInOrder: return "One file, in toolpath order"
        case .filePerToolpath: return "One file per toolpath"
        case .filePerTool: return "One file per tool"
        }
    }

    var isSingleFile: Bool { self == .oneFileGroupedByTool || self == .oneFileInOrder }
}

/// A planned output file.
struct PlannedGCodeFile: Equatable {
    var fileName: String
    var title: String
    var toolpaths: [Toolpath]
}

enum GCodeBatchExport {
    /// Splits the enabled operations' calculated toolpaths into files. Operations without
    /// toolpaths are skipped.
    static func plan(mode: SaveAllMode, operations: [AnyOperation], results: [UUID: ToolpathResult],
                     jobName: String, profile: PostProfile) -> [PlannedGCodeFile] {
        let enabled = operations.filter(\.setup.isEnabled)
        var files: [PlannedGCodeFile] = []
        switch mode {
        case .oneFileGroupedByTool, .oneFileInOrder:
            let tps = GCodeExporter.toolpaths(scope: .all, operations: operations, results: results,
                                              groupByTool: mode == .oneFileGroupedByTool)
            if !tps.isEmpty {
                files.append(PlannedGCodeFile(
                    fileName: GCodeExporter.suggestedFileName(jobName: jobName, operationName: nil, profile: profile),
                    title: "All toolpaths", toolpaths: tps))
            }
        case .filePerToolpath:
            for op in enabled {
                let tps = GCodeExporter.operationToolpaths(op, results: results)
                guard !tps.isEmpty else { continue }
                files.append(PlannedGCodeFile(
                    fileName: GCodeExporter.suggestedFileName(jobName: jobName, operationName: op.setup.name,
                                                              profile: profile),
                    title: op.setup.name, toolpaths: tps))
            }
        case .filePerTool:
            // Same safety rules as the grouped single file: a tool only gets one file when its
            // toolpaths can safely run together; otherwise it is split (profiles never move).
            let tps = GCodeExporter.toolpaths(scope: .all, operations: operations, results: results, groupByTool: false)
            let groups = ToolpathOrdering.toolGroups(tps)
            let width = max(2, String(groups.count).count)
            for (i, group) in groups.enumerated() {
                guard let tool = group.first?.tool else { continue }
                let seq = String(repeating: "0", count: width - String(i + 1).count) + String(i + 1)
                files.append(PlannedGCodeFile(
                    fileName: seq + "_" + GCodeExporter.suggestedFileName(
                        jobName: jobName, operationName: "T\(tool.number)_\(tool.name)", profile: profile),
                    title: "\(i + 1). " + JobSummary.label(tool), toolpaths: group))
            }
        }
        return uniquified(files)
    }

    /// "a.tap", "a.tap" → "a.tap", "a_2.tap".
    static func uniquified(_ files: [PlannedGCodeFile]) -> [PlannedGCodeFile] {
        var used = Set<String>()
        return files.map { f in
            var out = f
            let ext = (f.fileName as NSString).pathExtension
            let base = (f.fileName as NSString).deletingPathExtension
            var n = 2
            while used.contains(GCodeFileSet.collisionKey(out.fileName)) {
                out.fileName = "\(base)_\(n)" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }
            used.insert(GCodeFileSet.collisionKey(out.fileName))
            return out
        }
    }

    /// Posts every planned file (validator included). `GCodeFileSet(posted:)` writes the result.
    static func post(_ files: [PlannedGCodeFile], project: LoftLineProject, profile: PostProfile,
                     jobName: String, sheetToolpaths: SheetToolpaths? = nil) -> [(file: PlannedGCodeFile, result: GCodeExportResult)] {
        files.map { ($0, GCodeExporter.export(project: project, toolpaths: $0.toolpaths, profile: profile, jobName: jobName,
                                               sheetToolpaths: sheetToolpaths)) }
    }
}
