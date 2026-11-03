import CADCore
import Foundation

/// Several toolpaths cut as one: the children are generated in order and consecutive results
/// that use the same tool, and have the same material cleared above them, are joined into a
/// single toolpath (one tool load, no tool change).
public struct MergeOperation: ToolpathOperation {
    public static let kind = OperationKind.merge
    public var setup: OperationSetup
    public var params: MergeParameters

    public init(setup: OperationSetup, params: MergeParameters = MergeParameters()) {
        self.setup = setup
        self.params = params
    }

    public func generate(in context: CAMContext) throws -> [Toolpath] {
        guard !params.children.isEmpty else { throw CAMError.invalidParameter("Nothing to merge") }
        var pieces: [Toolpath] = []
        for child in params.children {
            do {
                pieces += try child.generate(in: context)
            } catch let error as CAMError {
                throw CAMError.invalidParameter("\(child.setup.name): \(Self.describe(error))")
            }
        }
        var out: [Toolpath] = []
        for tp in pieces {
            // Pieces join only when the material cleared above them is the same: a joined toolpath
            // carries one cleared depth, and a tiled export may later keep only some of its moves,
            // so a value true of the whole but of no one piece would misjudge the tiles.
            // An inlay part or relief side marker survives the merge: the validator refuses a pocket and its plug (or a
            // relief's top and bottom) in one program by reading it. Pieces with different markers stay apart; an
            // unmarked piece joins a marked one, which keeps the marker.
            if var last = out.last, last.tool.id == tp.tool.id, last.spindleRPM == tp.spindleRPM,
               abs((last.clearedDepth ?? 0) - (tp.clearedDepth ?? 0)) < 1e-9,
               Self.markers.allSatisfy({ k in last.metadata[k] == nil || tp.metadata[k] == nil || last.metadata[k] == tp.metadata[k] }) {
                for k in Self.markers where last.metadata[k] == nil { last.metadata[k] = tp.metadata[k] }
                last.moves += tp.moves
                // A profile inside the merge keeps the "cut last" ordering protection.
                if tp.kind == .profile { last.kind = .profile }
                for (k, v) in tp.metadata where k == "warning" {
                    last.metadata[k] = last.metadata[k].map { "\($0); \(tp.name): \(v)" } ?? "\(tp.name): \(v)"
                }
                out[out.count - 1] = last
            } else {
                var t = tp
                t.id = UUID()
                t.name = setup.name
                t.operationID = setup.id
                t.metadata = tp.metadata["warning"].map { ["warning": "\(tp.name): \($0)"] } ?? [:]
                for k in Self.markers { t.metadata[k] = tp.metadata[k] }
                if t.kind != .profile { t.kind = .merge }
                out.append(t)
            }
        }
        for i in out.indices { out[i].metadata["merged"] = params.children.map(\.setup.name).joined(separator: ", ") }
        return out
    }

    /// Metadata that says which part of a job a piece cuts (inlay pocket or plug, relief top or bottom side).
    static let markers = ["part", "side"]

    static func describe(_ e: CAMError) -> String {
        switch e {
        case .notImplemented(let s), .invalidGeometry(let s), .invalidParameter(let s): return s
        case .missingTool: return "missing tool"
        case .missingModel: return "missing 3D model"
        case .noGeometry: return "no vectors selected"
        }
    }

    /// The parts as standalone operations (Split, and a template, which stores a merge as its parts): each takes the
    /// merge's on/off and coolant, and the last takes its pause, since inside the merge only the whole has those.
    public var standaloneParts: [AnyOperation] {
        let children = params.children
        return children.indices.map { i in
            var s = children[i].setup
            s.isEnabled = setup.isEnabled
            s.coolant = setup.coolant
            s.pauseAfter = i == children.count - 1 ? setup.pauseAfter : nil
            return children[i].with(setup: s)
        }
    }

    /// A merge of `ops` (merges among them are flattened), named `name`.
    public static func merging(_ ops: [AnyOperation], name: String) -> MergeOperation? {
        var children: [AnyOperation] = []
        for op in ops {
            if case .merge(let m) = op { children += m.params.children } else { children.append(op) }
        }
        guard let first = children.first else { return nil }
        var shapeIDs: [UUID] = []
        for c in children { for id in c.setup.shapeIDs where !shapeIDs.contains(id) { shapeIDs.append(id) } }
        // Children are always cut, and only the merged operation as a whole can pause the machine.
        children = children.map { c in var s = c.setup; s.isEnabled = true; s.pauseAfter = nil; return c.with(setup: s) }
        return MergeOperation(setup: OperationSetup(name: name, toolID: first.setup.toolID, shapeIDs: shapeIDs),
                              params: MergeParameters(children: children))
    }
}
