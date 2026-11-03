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
        operations = operations.givingRepeatedIDsNewOnes()
        return merged.setup.id
    }

    /// Puts a merged operation's toolpaths back in its place; its pause goes back on the last one.
    mutating func splitMerged(_ id: UUID) {
        guard let i = operationIndex(id), case .merge(let m) = operations[i] else { return }
        operations.replaceSubrange(i...i, with: m.standaloneParts)
        // Parts of a duplicated merge written before #123 may repeat ids already at the top level.
        operations = operations.givingRepeatedIDsNewOnes()
    }
}

extension AnyOperation {
    /// The same operation under another id (its merged parts keep theirs).
    func withID(_ id: UUID) -> AnyOperation {
        var op = self, s = op.editableSetup
        s.id = id
        op.editableSetup = s
        return op
    }

    /// A copy with a new id, and new ids for every part merged inside it, so splitting the copy cannot bring back an id
    /// the original holds (#123).
    func withNewIDs() -> AnyOperation {
        var op = withID(UUID())
        if case .merge(var m) = op {
            m.params.children = m.params.children.map { $0.withNewIDs() }
            op = .merge(m)
        }
        return op
    }
}

extension Array where Element == AnyOperation {
    /// Gives every operation whose id is already taken a new one (#123). Top-level ids are reserved first, in order, so a
    /// top-level operation keeps its id (and its results, selection and variable links) over a merged part; then merged
    /// parts are walked depth first. The first holder of an id always keeps it.
    func givingRepeatedIDsNewOnes() -> [AnyOperation] {
        var seen = Set<UUID>()
        var out = self
        for i in out.indices where !seen.insert(out[i].id).inserted {
            out[i] = out[i].withID(UUID())
            seen.insert(out[i].id)
        }
        func parts(_ ops: [AnyOperation]) -> [AnyOperation] {
            ops.map { child in
                var op = child
                if !seen.insert(op.id).inserted {
                    op = op.withID(UUID())
                    seen.insert(op.id)
                }
                if case .merge(var m) = op {
                    m.params.children = parts(m.params.children)
                    op = .merge(m)
                }
                return op
            }
        }
        for i in out.indices {
            if case .merge(var m) = out[i] {
                m.params.children = parts(m.params.children)
                out[i] = .merge(m)
            }
        }
        return out
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
