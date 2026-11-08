// Which toolpaths the 3D preview simulates. Owned by preview.
import CAMCore
import Foundation
import LoftLineKit

enum PreviewScope: String, CaseIterable, Identifiable {
    /// Every enabled, calculated toolpath (what Export G-code writes).
    case all
    /// Enabled toolpaths whose eye is on in the Toolpaths list.
    case visible
    /// Only the toolpath selected in the Toolpaths list (even when disabled).
    case selected

    var id: Self { self }
    static let storageKey = "loftline.previewScope"

    var title: String {
        switch self {
        case .all: return "All Toolpaths"
        case .visible: return "Visible Toolpaths"
        case .selected: return "Selected Toolpath"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return "No calculated toolpaths to simulate"
        case .visible: return "No visible calculated toolpaths"
        case .selected: return "Select a calculated toolpath in the Toolpaths list"
        }
    }

    /// Toolpaths to simulate, in machining order (grouped by tool when `groupByTool`).
    func toolpaths(operations: [AnyOperation], results: [UUID: ToolpathResult], hidden: Set<UUID>,
                   selected: UUID?, groupByTool: Bool) -> [Toolpath] {
        switch self {
        case .all:
            return GCodeExporter.toolpaths(scope: .all, operations: operations, results: results,
                                           groupByTool: groupByTool)
        case .visible:
            let ops = operations.filter { !hidden.contains($0.id) }
            return GCodeExporter.toolpaths(scope: .all, operations: ops, results: results, groupByTool: groupByTool)
        case .selected:
            guard let id = selected, operations.contains(where: { $0.id == id }) else { return [] }
            return GCodeExporter.toolpaths(scope: .operation(id), operations: operations, results: results,
                                           groupByTool: groupByTool)
        }
    }
}
