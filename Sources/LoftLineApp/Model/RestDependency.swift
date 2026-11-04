import CADCore
import CAMCore
import Foundation

/// Whether a rest pass's source has actually finished the surface. Generation checks that the source exists, is on,
/// comes first and cuts the same model and side; this checks its calculated result, which only the document has: a
/// source that failed, was not calculated, or produced no finishing toolpath leaves the surface unfinished, and the
/// rest pass would then cut its patches into bare stock. The export refuses such a program (`GCodeExporter.export`).
enum RestDependency {
    static func problem(_ op: AnyOperation, results: [UUID: ToolpathResult]) -> String? {
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

extension LoftLineDocument {
    /// Sets a model's two-sided split, shared by every relief of it (one undo step).
    func setReliefSplit(_ split: ReliefSplit?, model id: UUID) {
        perform("Two-Sided Split") { p in
            guard let i = p.document.models.firstIndex(where: { $0.id == id }) else { return }
            p.document.models[i].reliefSplit = split
        }
    }

    /// Confirms a model's split after an older file's sides disagreed: every relief of the model may be cut again.
    func useReliefSplit(model id: UUID) {
        perform("Use These Settings") { p in
            p.operations = p.operations.map { op in
                func cleared(_ o: AnyOperation) -> AnyOperation {
                    guard case .relief3D(var r) = o, r.params.modelID == id, r.params.twoSided?.splitNeedsReview == true
                    else { return o }
                    r.params.twoSided?.splitNeedsReview = nil
                    return .relief3D(r)
                }
                if case .merge(var m) = op { m.params.children = m.params.children.map(cleared); return .merge(m) }
                return cleared(op)
            }
        }
    }
}
