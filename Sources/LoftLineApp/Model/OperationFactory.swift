import CADCore
import CAMCore
import Foundation

extension AnyOperation {
    /// Read/write access to the common setup regardless of the concrete operation.
    var editableSetup: OperationSetup {
        get { setup }
        set {
            switch self {
            case .profile(var o): o.setup = newValue; self = .profile(o)
            case .pocket(var o): o.setup = newValue; self = .pocket(o)
            case .drill(var o): o.setup = newValue; self = .drill(o)
            case .vcarve(var o): o.setup = newValue; self = .vcarve(o)
            case .inlay(var o): o.setup = newValue; self = .inlay(o)
            case .fluting(var o): o.setup = newValue; self = .fluting(o)
            case .texture(var o): o.setup = newValue; self = .texture(o)
            case .relief3D(var o): o.setup = newValue; self = .relief3D(o)
            case .photoVCarve(var o): o.setup = newValue; self = .photoVCarve(o)
            case .engrave(var o): o.setup = newValue; self = .engrave(o)
            case .chamfer(var o): o.setup = newValue; self = .chamfer(o)
            case .holeMill(var o): o.setup = newValue; self = .holeMill(o)
            case .prism(var o): o.setup = newValue; self = .prism(o)
            case .merge(var o): o.setup = newValue; self = .merge(o)
            case .straightInlay(var o): o.setup = newValue; self = .straightInlay(o)
            case .moulding(var o): o.setup = newValue; self = .moulding(o)
            case .facing(var o): o.setup = newValue; self = .facing(o)
            }
        }
    }

    /// The depth settings of an operation that has them (profile, pocket, fluting, quick engrave, facing).
    var editableDepth: DepthSettings? {
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

    /// The operation with its operator pause removed, to compare what affects the toolpath.
    var withoutPause: AnyOperation {
        var copy = self
        var s = copy.editableSetup
        s.pauseAfter = nil
        copy.editableSetup = s
        return copy
    }

    /// Every library tool the operation references (primary + clearance/roughing tools).
    var referencedToolIDs: [UUID] {
        var ids = [setup.toolID]
        switch self {
        case .pocket(let o): ids += o.params.clearanceTools
        case .vcarve(let o): ids += o.params.clearanceTools.map(\.toolID)
        case .inlay(let o): ids += o.params.clearanceToolIDs
        case .relief3D(let o):
            if let c = o.params.roughing.toolID { ids.append(c) }
            if let r = o.params.finishing.restToolID { ids.append(r) }
        case .merge: return toolIDs
        default: break
        }
        return ids
    }

    /// The operation with every reference to tool `from` (primary, clearance, roughing, rest) pointing at `to`. Done on the
    /// operation's JSON, where a tool id is a UUID string no other field can equal, so it holds for every kind of
    /// operation and any parameter that later holds a tool.
    func remappingTool(_ from: UUID, to: UUID) -> AnyOperation {
        guard referencedToolIDs.contains(from), let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return self }
        let mapped = text.replacingOccurrences(of: from.uuidString, with: to.uuidString)
        return (try? JSONDecoder().decode(AnyOperation.self, from: Data(mapped.utf8))) ?? self
    }
}

/// Creates operations with sensible, unit-aware defaults (the parameter structs' defaults are
/// in inches; millimetre documents get them scaled by 25.4).
enum OperationFactory {
    /// Kinds offered in the "New toolpath" menu, in VCarve-like order.
    static let menuKinds: [OperationKind] = [.profile, .pocket, .facing, .drill, .holeMill, .engrave, .chamfer, .vcarve, .prism, .inlay, .straightInlay, .photoVCarve, .fluting, .moulding, .texture, .relief3D]

    /// Title in the "New toolpath" menus (Inlay opens the pocket + plug wizard).
    static func menuTitle(_ kind: OperationKind) -> String {
        switch kind {
        case .inlay: return "Inlay (Pocket + Plug)…"
        case .straightInlay: return "Straight-Wall Inlay (Pocket + Plug)"
        default: return kind.displayName
        }
    }

    /// Label of the primary tool picker for an operation kind.
    static func primaryToolTitle(_ kind: OperationKind) -> String {
        switch kind {
        case .pocket: return "Finish tool"
        case .vcarve, .inlay, .photoVCarve, .chamfer, .prism: return "V-bit"
        case .drill: return "Drill"
        case .relief3D: return "Finishing tool"
        default: return "Tool"
        }
    }

    /// Preferred tool kinds for an operation (first match in the library wins).
    static func preferredToolKinds(for kind: OperationKind) -> [ToolKind] {
        switch kind {
        case .profile, .pocket, .holeMill, .merge: return [.endMill, .ballNose]
        case .facing: return [.endMill]
        case .straightInlay: return [.endMill]
        case .moulding: return [.ballNose, .endMill, .vBit]
        case .drill: return [.drill, .endMill]
        case .vcarve, .inlay, .photoVCarve, .chamfer, .prism: return [.vBit, .engraving]
        case .engrave: return [.engraving, .vBit, .ballNose, .endMill]
        case .fluting: return [.ballNose, .vBit, .endMill]
        case .texture: return [.ballNose, .vBit]
        case .relief3D: return [.ballNose, .endMill]
        }
    }

    static func defaultTool(for kind: OperationKind, in library: ToolLibrary) -> Tool? {
        // Facing wants the widest cutter there is, to cover the area in fewer passes.
        // Library tools keep their own units, so the sizes are compared, not the numbers.
        func width(_ t: Tool) -> Double { t.diameter * t.units.millimeters }
        if kind == .facing, let wide = library.tools.filter({ $0.kind == .endMill }).max(by: { width($0) < width($1) }) {
            return wide
        }
        for k in preferredToolKinds(for: kind) {
            if let t = library.tools.first(where: { $0.kind == k }) { return t }
        }
        return library.tools.first
    }

    /// "Profile 1", "Profile 2"… unique among `existing`.
    static func defaultName(for kind: OperationKind, existing: [AnyOperation]) -> String {
        let names = Set(existing.map(\.setup.name))
        var n = existing.filter { $0.kind == kind }.count + 1
        while names.contains("\(kind.displayName) \(n)") { n += 1 }
        return "\(kind.displayName) \(n)"
    }

    /// Builds a new operation. Returns nil only for a 3D relief without any placed model.
    static func make(kind: OperationKind, project: LoftLineProject, library: ToolLibrary,
                     shapeIDs: [UUID]) -> AnyOperation? {
        let doc = project.document
        let f = LengthUnit.inch.factor(to: doc.units)
        let toolID = defaultTool(for: kind, in: library)?.id ?? UUID()
        let setup = OperationSetup(name: defaultName(for: kind, existing: project.operations),
                                   toolID: toolID, shapeIDs: shapeIDs)
        let thickness = doc.job.thickness
        switch kind {
        case .profile:
            var p = ProfileParameters().scaled(by: f)
            p.depth.cutDepth = thickness
            p.depth.followsThickness = true
            return .profile(ProfileOperation(setup: setup, params: p))
        case .pocket:
            var p = PocketParameters().scaled(by: f)
            p.depth.cutDepth = min(p.depth.cutDepth, thickness)
            return .pocket(PocketOperation(setup: setup, params: p))
        case .drill:
            var p = DrillParameters().scaled(by: f)
            p.cutDepth = min(p.cutDepth, thickness)
            return .drill(DrillOperation(setup: setup, params: p))
        case .vcarve:
            return .vcarve(VCarveOperation(setup: setup, params: VCarveParameters().scaled(by: f)))
        case .inlay:
            return .inlay(InlayOperation(setup: setup, params: InlayParameters().scaled(by: f)))
        case .fluting:
            return .fluting(FlutingOperation(setup: setup, params: FlutingParameters().scaled(by: f)))
        case .texture:
            return .texture(TextureOperation(setup: setup, params: TextureParameters().scaled(by: f)))
        case .photoVCarve:
            var s = setup
            s.shapeIDs = []
            return .photoVCarve(PhotoVCarveOperation(setup: s, params: PhotoVCarveParameters().scaled(by: f)
                .fitted(in: doc.job)))
        case .engrave:
            return .engrave(EngraveOperation(setup: setup, params: EngraveParameters().scaled(by: f)))
        case .chamfer:
            return .chamfer(ChamferOperation(setup: setup, params: ChamferParameters().scaled(by: f)))
        case .merge:
            return nil
        case .moulding:
            // With two or more vectors selected, the last one selected is the cross-section.
            var s = setup
            var p = MouldingParameters()
            if shapeIDs.count > 1, let last = shapeIDs.last {
                p.sectionShapeID = last
                s.shapeIDs = Array(shapeIDs.dropLast())
            }
            return .moulding(MouldingOperation(setup: s, params: p.scaled(by: f)))
        case .straightInlay:
            var p = StraightInlayParameters().scaled(by: f)
            p.plugDepth = min(p.plugDepth, thickness)
            return .straightInlay(StraightInlayOperation(setup: setup, params: p))
        case .prism:
            return .prism(PrismOperation(setup: setup, params: PrismParameters().scaled(by: f)))
        case .facing:
            var p = FacingParameters(area: shapeIDs.isEmpty ? .material : .vectors).scaled(by: f)
            p.depth.cutDepth = min(p.depth.cutDepth, thickness)
            return .facing(FacingOperation(setup: setup, params: p))
        case .holeMill:
            var p = HoleMillParameters().scaled(by: f)
            p.cutDepth = min(p.cutDepth, thickness)
            return .holeMill(HoleMillOperation(setup: setup, params: p))
        case .relief3D:
            guard let model = doc.models.first else { return nil }
            var s = setup
            s.shapeIDs = []
            var p = Relief3DParameters(modelID: model.id, boundaryShapeIDs: shapeIDs).scaled(by: f)
            // Roughing needs an end mill; the primary (finishing) tool is usually a ball nose.
            if library.tool(id: toolID)?.kind != .endMill {
                if let mill = library.tools.first(where: { $0.kind == .endMill }) {
                    p.roughing.toolID = mill.id
                } else {
                    p.roughing.isEnabled = false
                }
            }
            return .relief3D(Relief3DOperation(setup: s, params: p))
        }
    }
}

/// Cut depths that were set from the material thickness follow it (`DepthSettings.followsThickness`).
enum DepthFollow {
    /// `operations` after the material thickness changed from `old` to `new`: every following cut
    /// depth moves by the difference, so a through cut stays through and an overcut keeps its
    /// overcut. Hand-edited passes at or past the new depth are dropped (the cut depth is always
    /// the last pass).
    /// `affected` limits the change to the operations on the sheet whose thickness changed; a
    /// merged operation's parts are adjusted one by one, since each keeps its own depth.
    static func adjusted(_ operations: [AnyOperation], thicknessFrom old: Double, to new: Double,
                         where affected: (AnyOperation) -> Bool = { _ in true }) -> [AnyOperation] {
        let delta = new - old
        guard abs(delta) > 1e-12 else { return operations }
        return operations.map { op in
            guard affected(op) else { return op }
            if case .merge(var m) = op {
                m.params.children = adjusted(m.params.children, thicknessFrom: old, to: new)
                return .merge(m)
            }
            guard var d = op.editableDepth, d.followsThickness == true else { return op }
            d.cutDepth += delta
            if let passes = d.customPasses { d.customPasses = passes.filter { $0 < d.cutDepth - 1e-9 } }
            var copy = op
            copy.editableDepth = d
            return copy
        }
    }
}
