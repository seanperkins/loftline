import CADCore
import Foundation

/// Picks the vectors a template toolpath applies to in a new design.
public struct VectorSelector: Codable, Hashable, Sendable {
    public enum Geometry: String, Codable, CaseIterable, Sendable { case any, closed, open }

    /// Layer name to match (case-insensitive); nil = any layer.
    public var layerName: String?
    public var geometry: Geometry

    public init(layerName: String? = nil, geometry: Geometry = .any) {
        self.layerName = layerName; self.geometry = geometry
    }

    public func matches(_ shape: Shape, in document: Document) -> Bool {
        if let name = layerName {
            guard let layer = document.layer(id: shape.layerID),
                  layer.name.compare(name, options: .caseInsensitive) == .orderedSame else { return false }
        }
        switch geometry {
        case .any: return !shape.paths.isEmpty
        case .closed: return !shape.paths.isEmpty && shape.paths.allSatisfy(\.isClosed)
        case .open: return shape.paths.contains { !$0.isClosed }
        }
    }

    /// Selector describing `shapes`: their most common layer and their open/closed kind.
    public static func describing(_ shapes: [Shape], in document: Document) -> VectorSelector {
        var counts: [String: Int] = [:]
        for s in shapes { if let l = document.layer(id: s.layerID) { counts[l.name, default: 0] += 1 } }
        let layer = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        let paths = shapes.flatMap(\.paths)
        let geometry: Geometry = paths.isEmpty ? .any
            : paths.allSatisfy(\.isClosed) ? .closed
            : paths.allSatisfy({ !$0.isClosed }) ? .open : .any
        return VectorSelector(layerName: layer, geometry: geometry)
    }
}

/// A saved set of toolpaths that can be re-applied to another design: every operation keeps its
/// parameters and tools, and picks its vectors again with a `VectorSelector`.
public struct ToolpathTemplate: Codable, Hashable, Sendable {
    public static let fileExtension = "loftlinetoolpaths"
    /// 2: a rest pass names the toolpath it follows and a two-sided relief carries its model's split (`Entry.reliefSplit`).
    /// A version 1 reader refuses version 2 (`decode`); this one upgrades version 1.
    public static let currentFormatVersion = 2

    public struct Entry: Codable, Hashable, Sendable {
        /// The operation with its vector references removed.
        public var operation: AnyOperation
        public var selector: VectorSelector
        /// A relief's model's two-sided split, in the template's units, for the model the relief is applied to.
        public var reliefSplit: ReliefSplit?

        public init(operation: AnyOperation, selector: VectorSelector, reliefSplit: ReliefSplit? = nil) {
            self.operation = operation; self.selector = selector; self.reliefSplit = reliefSplit
        }
    }

    public var formatVersion: Int
    /// Units the operations' lengths are in.
    public var units: LengthUnit
    public var entries: [Entry]
    /// Tools the operations use (so the template works without the original library).
    public var tools: [Tool]

    public init(units: LengthUnit, entries: [Entry], tools: [Tool]) {
        formatVersion = Self.currentFormatVersion
        self.units = units; self.entries = entries; self.tools = tools
    }

    /// Template from `project`'s operations (all, or those in `operationIDs`, in project order).
    public static func make(from project: LoftLineProject, operationIDs: Set<UUID>? = nil, library: ToolLibrary) -> ToolpathTemplate {
        let doc = project.document
        let lib = project.mergedTools(with: library)
        var entries: [Entry] = []
        var tools: [Tool] = []
        // A merged toolpath is stored as its children (each needs its own vectors).
        let ops = project.operations.filter { operationIDs?.contains($0.id) ?? true }.flatMap { op -> [AnyOperation] in
            if case .merge(let m) = op { return m.standaloneParts }
            return [op]
        }
        let included = Set(ops.map(\.id))
        let all = ReliefUpgrade.flat(project.operations)
        for op in ops {
            let selector = VectorSelector.describing(doc.shapes(ids: op.setup.shapeIDs), in: doc)
            var stored = op.detachedFromDesign()
            var split: ReliefSplit?
            var restTool: UUID?
            if case .relief3D(var r) = stored {
                split = doc.model(id: r.params.modelID)?.reliefSplit
                // A rest pass whose source is not in the template cannot name it: it keeps the source's tool, to be
                // resolved (or chosen) where the template is applied.
                if case .operation(let src)? = r.params.finishing.rest, !included.contains(src),
                   let source = all.first(where: { $0.id == src }) {
                    restTool = source.setup.toolID
                    r.params.finishing.rest = .unresolved(toolID: source.setup.toolID)
                    stored = .relief3D(r)
                }
            }
            entries.append(Entry(operation: stored, selector: selector, reliefSplit: split))
            for id in op.toolIDs + [restTool].compactMap({ $0 }) where !tools.contains(where: { $0.id == id }) {
                if let t = lib.tool(id: id) { tools.append(t) }
            }
        }
        return ToolpathTemplate(units: doc.units, entries: entries, tools: tools)
    }

    /// Operations for `document`: fresh ids, vectors chosen by each selector (in document order).
    /// 3D reliefs take the document's first model (and are left out when it has none). Lengths
    /// are still in `units`; the caller converts them.
    /// A relief comes with its entry's split (in the template's units) for the model it was applied to; a rest pass
    /// names its source's fresh id.
    public func resolve(in document: Document) -> [(operation: AnyOperation, matched: Int, split: ReliefSplit?)] {
        var out: [(AnyOperation, Int, ReliefSplit?)] = []
        let fresh = Dictionary(uniqueKeysWithValues: entries.map { ($0.operation.id, UUID()) })
        for e in entries {
            var op = e.operation.detachedFromDesign()
            var setup = op.setup
            setup.id = fresh[e.operation.id] ?? UUID()
            if case .relief3D(var r) = op {
                guard let model = document.models.first else { continue }
                r.params.modelID = model.id
                if case .operation(let src)? = r.params.finishing.rest, let id = fresh[src] {
                    r.params.finishing.rest = .operation(id)
                }
                r.setup = setup
                out.append((.relief3D(r), 1, e.reliefSplit))
                continue
            }
            // A facing of the whole material takes no vectors: whatever its (empty) selector would match must not decide
            // which sheet and side it belongs to, and it is never "unmatched".
            if case .facing(let f) = op, f.params.area == .material {
                out.append((op.with(setup: setup), 1, nil))
                continue
            }
            setup.shapeIDs = document.shapes.filter { e.selector.matches($0, in: document) }.map(\.id)
            op = op.with(setup: setup)
            out.append((op, setup.shapeIDs.count, nil))
        }
        return out
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(from data: Data) throws -> ToolpathTemplate {
        var t = try JSONDecoder().decode(ToolpathTemplate.self, from: data)
        guard t.formatVersion <= currentFormatVersion else {
            throw CAMError.invalidParameter("This toolpath template was saved by a newer version of LoftLine")
        }
        if t.formatVersion < 2 { t.upgradeFromVersion1() }
        return t
    }

    /// Version 1 stored a rest tool and each relief's own split: rest passes resolve within the template, by the
    /// nearest earlier finish with that tool, and each relief's split moves to its entry.
    mutating func upgradeFromVersion1() {
        let ordered = entries.map(\.operation)
        for i in entries.indices {
            var op = ReliefUpgrade.resolvingRest(entries[i].operation, among: ordered)
            if case .relief3D(var r) = op, let legacy = r.params.twoSided?.legacySplit {
                entries[i].reliefSplit = entries[i].reliefSplit ?? legacy
                r.params.twoSided?.legacySplit = nil
                op = .relief3D(r)
            }
            entries[i].operation = op
        }
        formatVersion = Self.currentFormatVersion
    }
}

extension AnyOperation {
    /// The same operation with a different common setup.
    public func with(setup: OperationSetup) -> AnyOperation {
        switch self {
        case .profile(var o): o.setup = setup; return .profile(o)
        case .pocket(var o): o.setup = setup; return .pocket(o)
        case .drill(var o): o.setup = setup; return .drill(o)
        case .vcarve(var o): o.setup = setup; return .vcarve(o)
        case .inlay(var o): o.setup = setup; return .inlay(o)
        case .fluting(var o): o.setup = setup; return .fluting(o)
        case .texture(var o): o.setup = setup; return .texture(o)
        case .relief3D(var o): o.setup = setup; return .relief3D(o)
        case .engrave(var o): o.setup = setup; return .engrave(o)
        case .chamfer(var o): o.setup = setup; return .chamfer(o)
        case .holeMill(var o): o.setup = setup; return .holeMill(o)
        case .prism(var o): o.setup = setup; return .prism(o)
        case .merge(var o): o.setup = setup; return .merge(o)
        case .straightInlay(var o): o.setup = setup; return .straightInlay(o)
        case .moulding(var o): o.setup = setup; return .moulding(o)
        case .facing(var o): o.setup = setup; return .facing(o)
        case .photoVCarve(var o): o.setup = setup; return .photoVCarve(o)
        }
    }

    /// Every tool the operation uses (primary first).
    public var toolIDs: [UUID] {
        var ids = [setup.toolID]
        switch self {
        case .pocket(let o): ids += o.params.clearanceTools
        case .vcarve(let o): ids += o.params.clearanceTools.map(\.toolID).filter { !ids.contains($0) }
        case .inlay(let o): ids += o.params.clearanceToolIDs.filter { !ids.contains($0) }
        case .relief3D(let o):
            if let c = o.params.roughing.toolID { ids.append(c) }

        case .merge(let o):
            for c in o.params.children { ids += c.toolIDs.filter { !ids.contains($0) } }
        default: break
        }
        return ids
    }

    /// The operation without references to particular vectors (selected shapes, manual tabs,
    /// relief boundaries), ready to be stored in a template.
    public func detachedFromDesign() -> AnyOperation {
        var s = setup
        s.shapeIDs = []
        s.projectOntoModelID = nil
        switch with(setup: s) {
        case .profile(var o):
            if o.params.tabs.manualTabs != nil { o.params.tabs.manualTabs = nil }
            return .profile(o)
        case .relief3D(var o):
            o.params.boundaryShapeIDs = []
            o.params.additionalModelIDs = nil
            return .relief3D(o)
        case .moulding(var o):
            o.params.sectionShapeID = nil
            return .moulding(o)
        case let other:
            return other
        }
    }
}
