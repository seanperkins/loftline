import CADCore
import CAMCore
import Foundation

/// Whether a rest pass's source has actually finished the surface. Generation checks that the source exists, is on,
/// comes first and cuts the same model and side; this checks its calculated result, which only the document has: a
/// source that failed, was not calculated, or produced no finishing toolpath leaves the surface unfinished, and the
/// rest pass would then cut its patches into bare stock. The export refuses such a program (`GCodeExporter.export`).
public enum RestDependency {
    public static func problem(_ op: AnyOperation, results: [UUID: ToolpathResult]) -> String? {
        guard case .relief3D(let r) = op, r.params.finishing.isEnabled, case .operation(let id)? = r.params.finishing.rest
        else { return nil }
        guard let result = results[id] else {
            return "\(op.setup.name): the toolpath it rests after is not calculated"
        }
        let finished = result.error == nil
            && result.toolpaths.contains { $0.metadata["pass"] == "finishing" && !$0.moves.isEmpty }
        return finished ? nil : "Rest after \"\(result.operation.setup.name)\": it has no finishing toolpath"
    }
}
