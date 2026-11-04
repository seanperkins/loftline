import CADCore
import CAMCore
import Foundation

/// Merging adjacent toolpaths that use the same tool, and splitting them again (toolpaths-2d).
extension LoftLineProject {
    /// Why the operation cannot be merged with the one after it (nil = it can).
    public func mergeWithNextProblem(_ id: UUID) -> String? {
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
    public mutating func mergeWithNext(_ id: UUID) -> UUID? {
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
    public mutating func splitMerged(_ id: UUID) {
        guard let i = operationIndex(id), case .merge(let m) = operations[i] else { return }
        operations.replaceSubrange(i...i, with: m.standaloneParts)
        // Parts of a duplicated merge written before #123 may repeat ids already at the top level.
        operations = operations.givingRepeatedIDsNewOnes()
    }
}

extension AnyOperation {
    /// The same operation under another id (its merged parts keep theirs).
    public func withID(_ id: UUID) -> AnyOperation {
        var op = self, s = op.editableSetup
        s.id = id
        op.editableSetup = s
        return op
    }

    /// A copy with a new id, and new ids for every part merged inside it, so splitting the copy cannot bring back an id
    /// the original holds (#123).
    public func withNewIDs() -> AnyOperation {
        var op = withID(UUID())
        if case .merge(var m) = op {
            m.params.children = m.params.children.map { $0.withNewIDs() }
            op = .merge(m)
        }
        return op
    }
}

extension Array where Element == AnyOperation {
    /// In program order with merged parts in place.
    public var flattened: [AnyOperation] {
        flatMap { op -> [AnyOperation] in
            if case .merge(let m) = op { return m.params.children }
            return [op]
        }
    }

    /// Gives every operation whose id is already taken a new one (#123). Top-level ids are reserved first, in order, so a
    /// top-level operation keeps its id (and its results, selection and variable links) over a merged part; then merged
    /// parts are walked depth first. The first holder of an id always keeps it.
    public func givingRepeatedIDsNewOnes() -> [AnyOperation] {
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
