import CADCore
import Foundation

public enum OperationKind: String, Codable, CaseIterable, Sendable {
    case profile, pocket, drill, vcarve, inlay, fluting, texture, relief3D, photoVCarve
    // toolpaths-2d additions
    case engrave, chamfer, holeMill, prism, merge, straightInlay, moulding, facing

    public var displayName: String {
        switch self {
        case .profile: return "Profile"
        case .pocket: return "Pocket"
        case .drill: return "Drilling"
        case .vcarve: return "V-Carve"
        case .inlay: return "Inlay"
        case .fluting: return "Fluting"
        case .texture: return "Texture"
        case .relief3D: return "3D Relief"
        case .photoVCarve: return "Photo V-Carve"
        case .engrave: return "Quick Engrave"
        case .chamfer: return "Chamfer"
        case .holeMill: return "Hole Milling"
        case .prism: return "Prism Carve"
        case .merge: return "Merged"
        case .straightInlay: return "Straight Inlay"
        case .moulding: return "Moulding"
        case .facing: return "Facing"
        }
    }
}

public enum CAMError: Error, Equatable, Sendable {
    case notImplemented(String)
    case missingTool(UUID)
    case missingModel(UUID)
    case noGeometry
    /// e.g. an open vector given to a pocket.
    case invalidGeometry(String)
    case invalidParameter(String)
}

/// Common settings of every operation (VCarve's toolpath name / tool / selected vectors).
public struct OperationSetup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    /// Primary tool (library ID).
    public var toolID: UUID
    /// Selected vectors.
    public var shapeIDs: [UUID]
    /// When set, the generated 2D toolpaths are dropped onto this 3D model's surface: depths
    /// become depths below the surface (see `ReliefProjection`). nil = cut from the material top.
    public var projectOntoModelID: UUID?
    /// This toolpath's changes to the primary tool's cutting data (toolpaths-2d addition).
    public var toolOverride: ToolOverride?
    /// Repeat the generated toolpath on a grid (toolpaths-2d addition; nil = once).
    public var arrayCopy: ArrayCopySettings?
    /// Stop the machine for the operator after this toolpath (nil = run straight on). Applied when
    /// the program is posted, so changing it never needs a recalculation.
    public var pauseAfter: PauseStep?
    /// Coolant for every toolpath this operation makes (nil = Off). Applied when the program is posted.
    public var coolant: Coolant?

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, toolID: UUID, shapeIDs: [UUID] = []) {
        self.id = id; self.name = name; self.isEnabled = isEnabled; self.toolID = toolID; self.shapeIDs = shapeIDs
    }
}

/// Everything a generator needs. Value type: generators are pure functions of it.
public struct CAMContext: Sendable {
    public var document: Document
    public var tools: ToolLibrary
    /// Chordal tolerance for flattening curves (document units).
    public var tolerance: Double

    public init(document: Document, tools: ToolLibrary, tolerance: Double? = nil) {
        self.document = document
        self.tools = tools
        self.tolerance = tolerance ?? Self.defaultTolerance(document.units)
    }

    /// The chordal tolerance a context uses unless told otherwise; also the slack the design-time
    /// checks allow, so a form and the toolpath agree at the margin.
    public static func defaultTolerance(_ units: LengthUnit) -> Double { units == .inch ? 0.0005 : 0.01 }

    public var coords: MachineCoordinates { MachineCoordinates(job: document.job) }
    public var units: LengthUnit { document.units }

    /// Per-toolpath changes to a tool's cutting data, by tool id (set by `AnyOperation.generate`
    /// from the operation's `toolOverride`; toolpaths-2d addition).
    public var toolOverrides: [UUID: ToolOverride] = [:]

    /// Library tool converted to document units, with the job material's cutting data and any
    /// per-toolpath override applied.
    public func tool(_ id: UUID) throws -> Tool {
        guard let t = tools.tool(id: id) else { throw CAMError.missingTool(id) }
        var out = t.forMaterial(document.job.material).converted(to: document.units)
        if let o = toolOverrides[id] { out = o.applied(to: out) }
        return out
    }

    public func shapes(for setup: OperationSetup) -> [Shape] { document.shapes(ids: setup.shapeIDs) }
}

/// A configured toolpath operation. Implementations live in the workstream folders
/// (Ops2D, OpsVCarve, Ops3D); parameters live in Model/Parameters.
public protocol ToolpathOperation: Codable, Hashable, Sendable {
    static var kind: OperationKind { get }
    var setup: OperationSetup { get set }
    /// Generate toolpaths (one per tool used, in cutting order).
    func generate(in context: CAMContext) throws -> [Toolpath]
}
