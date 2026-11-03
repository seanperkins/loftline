import CADCore
import Foundation

extension AnyOperation {
    /// The depth settings of an operation that has them (profile, pocket, fluting, quick engrave, facing).
    public var editableDepth: DepthSettings? {
        get {
            switch self {
            case .profile(let o): return o.params.depth
            case .pocket(let o): return o.params.depth
            case .fluting(let o): return o.params.depth
            case .engrave(let o): return o.params.depth
            case .facing(let o): return o.params.depth
            default: return nil
            }
        }
        set {
            guard let d = newValue else { return }
            switch self {
            case .profile(var o): o.params.depth = d; self = .profile(o)
            case .pocket(var o): o.params.depth = d; self = .pocket(o)
            case .fluting(var o): o.params.depth = d; self = .fluting(o)
            case .engrave(var o): o.params.depth = d; self = .engrave(o)
            case .facing(var o): o.params.depth = d; self = .facing(o)
            default: break
            }
        }
    }
}

extension LoftLineProject {
    /// The material sheet an operation is machined on (nil when its vectors span sheets). An operation with no vectors
    /// on a multi-sheet job (a whole-material facing) is on the primary sheet.
    public func sheetID(of op: AnyOperation) -> UUID? {
        guard document.isMultiSheet else { return document.currentSheetID }
        if op.setup.shapeIDs.isEmpty { return MaterialSheet.primaryID }
        return document.sheetID(ofShapes: op.setup.shapeIDs)
    }

    /// Every through cut's `cutDepth` set to its sheet's thickness plus its overcut (merged parts one by one), with
    /// hand-edited passes at or past the new depth dropped, since the cut depth is always the last pass. An operation
    /// whose vectors span sheets keeps its depth. A file's legacy `followsThickness` flag becomes an overcut first: a
    /// depth at or past the bottom keeps its distance past it; a depth above the bottom had been edited by hand after
    /// the flag was set, which the flag ignored, so it becomes a fixed depth.
    ///
    /// `old` is the project before an edit: a through cut whose `cutDepth` the edit changed while its overcut stayed
    /// the same had its depth typed (or linked to an expression), so it becomes a fixed depth at that value.
    public func resolvingThroughDepths(from old: LoftLineProject? = nil) -> LoftLineProject {
        var p = self
        let tol = document.units == .inch ? 0.0005 : 0.01
        var before: [UUID: DepthSettings] = [:]
        func index(_ op: AnyOperation) {
            if case .merge(let m) = op { m.params.children.forEach(index); return }
            if let d = op.editableDepth { before[op.id] = d }
        }
        // After a unit change every length is rescaled, an overcut of 0 included, so nothing was typed.
        if let old, old.document.units == document.units { old.operations.forEach(index) }
        func resolved(_ op: AnyOperation, thickness: Double?) -> AnyOperation {
            if case .merge(var m) = op {
                m.params.children = m.params.children.map { resolved($0, thickness: thickness) }
                return .merge(m)
            }
            guard var d = op.editableDepth else { return op }
            if d.followsThickness == true, d.overcut == nil, let t = thickness {
                d.overcut = d.cutDepth >= t - tol ? d.cutDepth - t : nil
            }
            d.followsThickness = nil
            if let o = before[op.id], let over = d.overcut, o.overcut == over, abs(o.cutDepth - d.cutDepth) > 1e-12 {
                d.overcut = nil
            }
            if let over = d.overcut, let t = thickness {
                d.cutDepth = t + over
                if let passes = d.customPasses { d.customPasses = passes.filter { $0 < d.cutDepth - 1e-9 } }
            }
            guard d != op.editableDepth else { return op }
            var copy = op
            copy.editableDepth = d
            return copy
        }
        p.operations = operations.map { op in
            resolved(op, thickness: sheetID(of: op).flatMap { document.job(ofSheet: $0)?.thickness })
        }
        return p
    }
}
