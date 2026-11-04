import CADCore
import CAMCore
import Foundation

/// The "Place 3D Model" dialog shown after importing an STL (and from the model's context
/// menu): XY size (aspect locked), position, Z height and offset below the material top, and
/// optionally Roughing + Finishing toolpaths. Lengths are in document units.
public struct ModelPlacementForm: Equatable {
    public enum Position: String, CaseIterable, Identifiable {
        case center, lowerLeft, custom
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .center: return "Center of material"
            case .lowerLeft: return "Lower-left corner"
            case .custom: return "Custom"
            }
        }
    }

    public var modelID: UUID
    public var name: String
    public let mesh: Mesh3D
    /// Mesh extents (document units) before scaling.
    public let meshSize: Vec3
    public let job: JobSetup

    public private(set) var width: Double
    public private(set) var height: Double
    public var position: Position
    /// Lower-left corner of the model footprint (material frame) when `position == .custom`.
    public var x: Double
    public var y: Double
    /// Distance from the model's lowest to highest point after placement.
    public var zHeight: Double
    /// How far the model's top sits below the material top.
    public var zOffset: Double

    public var createToolpaths: Bool
    public var roughingToolID: UUID?
    public var finishingToolID: UUID?

    /// New placement for an imported mesh: native size (shrunk to fit the material if needed),
    /// centred, top flush with the material top, height clamped to the material thickness.
    public init(mesh: Mesh3D, name: String, job: JobSetup, library: ToolLibrary) {
        modelID = UUID()
        self.name = name.isEmpty ? "Model" : name
        self.mesh = mesh
        self.job = job
        let b = mesh.bounds
        meshSize = b.map { Vec3($0.max.x - $0.min.x, $0.max.y - $0.min.y, $0.max.z - $0.min.z) } ?? Vec3(0, 0, 0)
        var s = 1.0
        if meshSize.x > job.width || meshSize.y > job.height, meshSize.x > 0, meshSize.y > 0 {
            s = min(job.width / meshSize.x, job.height / meshSize.y)
        }
        width = meshSize.x * s
        height = meshSize.y * s
        position = .center
        x = 0; y = 0
        let h = meshSize.z > 0 ? meshSize.z : job.thickness / 2
        zHeight = min(h, job.thickness)
        zOffset = 0
        createToolpaths = true
        roughingToolID = library.tools.first { $0.kind == .endMill }?.id
        finishingToolID = (library.tools.first { $0.kind == .ballNose } ?? library.tools.first { $0.kind == .endMill })?.id
        let o = origin
        x = o.x; y = o.y
    }

    /// Editing an existing placed model (no new toolpaths by default).
    public init(editing model: PlacedModel, job: JobSetup, library: ToolLibrary) {
        self.init(mesh: model.mesh, name: model.name, job: job, library: library)
        modelID = model.id
        width = meshSize.x * model.scale
        height = meshSize.y * model.scale
        zOffset = model.zTop
        zHeight = model.depth - model.zTop
        let fp = model.footprint
        position = .custom
        x = fp.min.x; y = fp.min.y
        createToolpaths = false
    }

    public var aspect: Double { meshSize.y > 0 ? meshSize.x / meshSize.y : 1 }
    public var scale: Double { meshSize.x > 0 ? width / meshSize.x : (meshSize.y > 0 ? height / meshSize.y : 1) }

    public mutating func setWidth(_ w: Double) {
        guard w > 0 else { return }
        width = w
        height = meshSize.x > 0 ? meshSize.y * w / meshSize.x : height
    }

    public mutating func setHeight(_ h: Double) {
        guard h > 0 else { return }
        height = h
        width = meshSize.y > 0 ? meshSize.x * h / meshSize.y : width
    }

    /// Lower-left corner of the footprint for the chosen position.
    public var origin: Vec2 {
        switch position {
        case .center: return Vec2((job.width - width) / 2, (job.height - height) / 2)
        case .lowerLeft: return .zero
        case .custom: return Vec2(x, y)
        }
    }

    public var placedModel: PlacedModel {
        let s = scale
        let minXY = mesh.bounds.map { Vec2($0.min.x, $0.min.y) } ?? .zero
        return PlacedModel(id: modelID, name: name, mesh: mesh, offset: origin - minXY * s, scale: s,
                           depth: zOffset + max(zHeight, 0), zTop: zOffset)
    }

    public var warnings: [String] {
        var out: [String] = []
        if zOffset + zHeight > job.thickness + 1e-9 { out.append("The model goes deeper than the material thickness.") }
        let o = origin
        if o.x < -1e-9 || o.y < -1e-9 || o.x + width > job.width + 1e-9 || o.y + height > job.height + 1e-9 {
            out.append("The model extends past the material edge.")
        }
        if zHeight <= 0 { out.append("Z height must be greater than zero.") }
        return out
    }

    /// Roughing (end mill) and Finishing (ball nose) toolpaths for the placed model.
    public func makeOperations(existing: [AnyOperation], units: LengthUnit) -> [AnyOperation] {
        guard createToolpaths else { return [] }
        let f = LengthUnit.inch.factor(to: units)
        let base = Relief3DParameters(modelID: modelID).scaled(by: f)
        var ops: [AnyOperation] = []
        if let rough = roughingToolID {
            var p = base
            p.roughing.isEnabled = true
            p.roughing.toolID = rough
            p.finishing.isEnabled = false
            ops.append(.relief3D(Relief3DOperation(setup: OperationSetup(name: "\(name) Roughing", toolID: rough),
                                                   params: p)))
        }
        if let finish = finishingToolID {
            var p = base
            p.roughing.isEnabled = false
            p.roughing.toolID = nil
            p.finishing.isEnabled = true
            ops.append(.relief3D(Relief3DOperation(setup: OperationSetup(name: "\(name) Finishing", toolID: finish),
                                                   params: p)))
        }
        let names = Set(existing.map(\.setup.name))
        return ops.map { op in
            var o = op
            var s = o.editableSetup
            var n = 2
            let base = s.name
            while names.contains(s.name) { s.name = "\(base) \(n)"; n += 1 }
            o.editableSetup = s
            return o
        }
    }
}
