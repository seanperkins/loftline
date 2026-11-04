import CADCore
import CAMCore
import Foundation
import LoftLineKit

extension LoftLineDocument {
    func mergeOperationWithNext(_ id: UUID) {
        var newID: UUID?
        perform("Merge Toolpaths") { newID = $0.mergeWithNext(id) }
        if let newID { selectedOperationID = newID }
    }

    func splitMergedOperation(_ id: UUID) {
        let first: UUID? = {
            if case .merge(let m) = operation(id) { return m.params.children.first?.id }
            return nil
        }()
        perform("Split Merged Toolpath") { $0.splitMerged(id) }
        if let first { selectedOperationID = first }
    }
}

extension LoftLineDocument {
    /// New Toolpath → Straight-Wall Inlay: a pocket operation and a (disabled) plug operation on
    /// the selected vectors, so each board's program is saved on its own.
    func addStraightInlayPair() {
        guard case .straightInlay(var pocket) = OperationFactory.make(kind: .straightInlay, project: project,
                                                                      library: mergedLibrary, shapeIDs: selectionOrder)
        else { return }
        let base = pocket.setup.name
        pocket.setup.name = "\(base) Pocket"
        pocket.params.part = .female
        var plug = pocket
        plug.setup = OperationSetup(name: "\(base) Plug", isEnabled: false, toolID: pocket.setup.toolID,
                                    shapeIDs: pocket.setup.shapeIDs)
        plug.params.part = .male
        perform("New Straight-Wall Inlay") { p in
            p.upsertOperation(.straightInlay(pocket))
            p.upsertOperation(.straightInlay(plug))
        }
        sidebarTab = .toolpaths
        selectedOperationID = pocket.setup.id
    }
}
