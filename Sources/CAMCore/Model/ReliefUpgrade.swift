import CADCore
import Foundation

/// Upgrades the relief state older files stored per toolpath (docs/implicit-state-machines.md #8): a rest tool becomes
/// the earlier finish that used it, and a two-sided split moves to the model both sides share.
enum ReliefUpgrade {
    /// `operations` in program order, merged parts in place.
    static func flat(_ operations: [AnyOperation]) -> [AnyOperation] {
        operations.flatMap { op -> [AnyOperation] in
            if case .merge(let m) = op { return m.params.children }
            return [op]
        }
    }

    /// Each `.unresolved(toolID:)` rest pass named after the nearest earlier 3D finish with that tool, among `ordered`
    /// (program order); without one it stays unresolved, which never generates.
    static func resolvingRest(_ op: AnyOperation, among ordered: [AnyOperation]) -> AnyOperation {
        guard case .relief3D(var r) = op, case .unresolved(let tool)? = r.params.finishing.rest,
              let me = ordered.firstIndex(where: { $0.id == op.id }) else { return op }
        let source = ordered[..<me].last { o in
            if case .relief3D(let s) = o { return s.params.finishing.isEnabled && s.setup.toolID == tool }
            return false
        }
        guard let source else { return op }
        r.params.finishing.rest = .operation(source.id)
        return .relief3D(r)
    }

    /// The split each model takes from its reliefs' `legacySplit` values: the shared one when they agree, the top
    /// side's (else the first) when they differ, with `conflicted` naming those models.
    static func splits(of reliefs: [Relief3DOperation]) -> (splits: [UUID: ReliefSplit], conflicted: Set<UUID>) {
        var byModel: [UUID: [(side: TwoSidedSettings.Side, split: ReliefSplit)]] = [:]
        for r in reliefs {
            guard let two = r.params.twoSided, let s = two.legacySplit else { continue }
            byModel[r.params.modelID, default: []].append((two.side, s))
        }
        var splits: [UUID: ReliefSplit] = [:], conflicted = Set<UUID>()
        for (model, list) in byModel {
            splits[model] = (list.first { $0.side == .top } ?? list[0]).split
            if Set(list.map(\.split)).count > 1 { conflicted.insert(model) }
        }
        return (splits, conflicted)
    }

    /// `op` with its legacy split cleared, and marked for review when its model's sides disagreed.
    static func clearingLegacySplit(_ op: AnyOperation, conflicted: Set<UUID>) -> AnyOperation {
        guard case .relief3D(var r) = op, r.params.twoSided != nil else { return op }
        let hadLegacy = r.params.twoSided?.legacySplit != nil
        r.params.twoSided?.legacySplit = nil
        if hadLegacy, conflicted.contains(r.params.modelID) { r.params.twoSided?.splitNeedsReview = true }
        return .relief3D(r)
    }

    static func map(_ operations: [AnyOperation], _ f: (AnyOperation) -> AnyOperation) -> [AnyOperation] {
        operations.map { op in
            if case .merge(var m) = op {
                m.params.children = m.params.children.map(f)
                return .merge(m)
            }
            return f(op)
        }
    }
}

extension LoftLineProject {
    /// The project with older relief state upgraded (see `ReliefUpgrade`). A model that already has a split keeps it.
    func upgradingReliefs() -> LoftLineProject {
        var p = self
        let ordered = ReliefUpgrade.flat(operations)
        let reliefs = ordered.compactMap { op -> Relief3DOperation? in if case .relief3D(let r) = op { return r } else { return nil } }
        let (splits, conflicted) = ReliefUpgrade.splits(of: reliefs)
        for i in p.document.models.indices where p.document.models[i].reliefSplit == nil {
            p.document.models[i].reliefSplit = splits[p.document.models[i].id]
        }
        p.operations = ReliefUpgrade.map(operations) {
            ReliefUpgrade.clearingLegacySplit(ReliefUpgrade.resolvingRest($0, among: ordered), conflicted: conflicted)
        }
        return p
    }
}
