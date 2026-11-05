import CADCore
import CAMCore
import Foundation
import LoftLineKit

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
