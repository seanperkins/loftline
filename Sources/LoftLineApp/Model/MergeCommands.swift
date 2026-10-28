import CADCore
import CAMCore
import Foundation

/// Merging adjacent toolpaths that use the same tool, and splitting them again (toolpaths-2d).
extension LoftLineProject {
    /// Why the operation cannot be merged with the one after it (nil = it can).
    func mergeWithNextProblem(_ id: UUID) -> String? {
        guard let i = operationIndex(id) else { return "Select a toolpath." }
        guard i + 1 < operations.count else { return "There is no toolpath after this one." }
        let a = operations[i], b = operations[i + 1]
        if a.kind == .relief3D || b.kind == .relief3D { return "3D toolpaths cannot be merged." }
        if a.setup.toolID != b.setup.toolID { return "The next toolpath uses a different tool." }
        if a.setup.coolant != b.setup.coolant { return "The next toolpath uses a different coolant." }
        // A merged operation is one toolpath; a stop in the middle of it has nowhere to go.
        if a.setup.pauseAfter != nil { return "This toolpath pauses the machine after it. Turn the pause off to merge it with the next one." }
        if a.setup.isEnabled != b.setup.isEnabled {
            return "One of the toolpaths is turned off; merging would turn it on."
        }
        return nil
    }

    /// Replaces the operation and the next one with one merged operation (cut in the same order).
    @discardableResult
    mutating func mergeWithNext(_ id: UUID) -> UUID? {
        guard mergeWithNextProblem(id) == nil, let i = operationIndex(id) else { return nil }
        let a = operations[i], b = operations[i + 1]
        let name: String
        if case .merge = a { name = a.setup.name } else { name = "\(a.setup.name) + \(b.setup.name)" }
        guard var merged = MergeOperation.merging([a, b], name: name) else { return nil }
        if case .merge = a { merged.setup.id = a.id }
        merged.setup.isEnabled = a.setup.isEnabled && b.setup.isEnabled
        // The pause after the last part is the pause after the whole.
        merged.setup.pauseAfter = b.setup.pauseAfter
        merged.setup.coolant = a.setup.coolant
        operations.replaceSubrange(i...(i + 1), with: [.merge(merged)])
        return merged.setup.id
    }

    /// Puts a merged operation's toolpaths back in its place; its pause goes back on the last one.
    mutating func splitMerged(_ id: UUID) {
        guard let i = operationIndex(id), case .merge(let m) = operations[i] else { return }
        var children = m.params.children.map { child in
            var c = child, s = child.editableSetup
            s.coolant = m.setup.coolant
            c.editableSetup = s
            return c
        }
        if let last = children.indices.last {
            var s = children[last].editableSetup
            s.pauseAfter = m.setup.pauseAfter
            children[last].editableSetup = s
        }
        operations.replaceSubrange(i...i, with: children)
    }
}

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
