import CADCore
import Foundation

/// 3D relief: heightmap from STL, z-level roughing + raster finishing (ball/flat/V tool).
///
/// Produces up to two toolpaths in cutting order: roughing (flat end mill, leaves
/// `roughing.allowance`) then finishing (primary tool, drop-cutter raster). The machined area
/// is the union of the closed boundary vectors, or the models' footprints when there are none;
/// the tool centre stays inside it. Several models (`additionalModelIDs`) are combined into one
/// composite surface. Outside the models' triangles the surface is the deepest model's
/// bottom plane (`PlacedModel.depth`).
public struct Relief3DOperation: ToolpathOperation {
    public static let kind = OperationKind.relief3D
    public var setup: OperationSetup
    public var params: Relief3DParameters

    public init(setup: OperationSetup, params: Relief3DParameters) {
        self.setup = setup
        self.params = params
    }

    public func generate(in context: CAMContext) throws -> [Toolpath] {
        guard let model = context.document.model(id: params.modelID) else { throw CAMError.missingModel(params.modelID) }
        let extraIDs = params.allModelIDs.dropFirst()
        let extras = extraIDs.compactMap { context.document.model(id: $0) }
        var models = ([model] + extras).filter { $0.mesh.triangleCount > 0 }
        guard !models.isEmpty else { throw CAMError.noGeometry }
        let job = context.document.job
        // Two-sided: the depth this side's surface is clamped at (this side's frame).
        var sideLimit: Double?
        let split = model.reliefSplit
        if let two = params.twoSided {
            guard two.splitNeedsReview != true else {
                throw CAMError.invalidParameter("Two-sided settings differed between the sides in the saved file: check "
                                                + "flip, split depth and web, then press Use These Settings")
            }
            guard let split else { throw CAMError.invalidParameter("Two-sided: the model has no split settings") }
            let splitDepth = ReliefTwoSided.splitDepth(split, model: model)
            guard splitDepth > model.zTop + 1e-9, splitDepth < model.depth - 1e-9 else {
                throw CAMError.invalidParameter("The two-sided split depth must lie between the model's top and bottom")
            }
            let limit = ReliefTwoSided.clampDepth(split, side: two.side, split: splitDepth, thickness: job.thickness)
            guard limit > 1e-9 else { throw CAMError.invalidParameter("The two-sided web leaves nothing to cut") }
            sideLimit = limit
            if two.side == .bottom { models = models.map { ReliefTwoSided.flipped($0, flip: split.flip, job: job) } }
        }
        guard params.roughing.isEnabled || params.finishing.isEnabled else {
            throw CAMError.invalidParameter("Enable roughing and/or finishing")
        }
        let finishTool = try context.tool(setup.toolID)
        let roughTool = try context.tool(params.roughing.toolID ?? setup.toolID)
        if params.roughing.isEnabled, roughTool.kind != .endMill {
            throw CAMError.invalidParameter("3D roughing needs an end mill")
        }

        let boundaryShapes = context.document.shapes(ids: params.boundaryShapeIDs)
        var region = ReliefRegion.polygons(of: boundaryShapes, tolerance: context.tolerance)
        if let two = params.twoSided, two.side == .bottom, let split {
            region = region.map { $0.map { ReliefTwoSided.mirror($0, flip: split.flip, job: job) } }
        }
        if region.isEmpty {
            region = GeomKernel.boolean(.union, subject: models.map { ReliefRegion.rectangle($0.footprint) }, clip: [],
                                        fillRule: .nonZero)
        }
        let regionBounds = Rect2(points: region.flatMap { $0 })
        guard !regionBounds.isEmpty, regionBounds.width > 0 || regionBounds.height > 0 else { throw CAMError.noGeometry }

        let restSource = params.finishing.isEnabled ? try restSource(in: context) : nil
        let restTool: Tool? = try restSource.map { try context.tool($0.setup.toolID) }
        let reach = max(finishTool.radius, roughTool.radius + max(0, params.roughing.allowance), restTool?.radius ?? 0)
        let area = regionBounds.insetBy(-(reach + 2 * params.resolution))
        var metadata: [String: String] = [:]
        var warnings: [String] = []
        if extras.count < extraIDs.count {
            warnings.append("\(extraIDs.count - extras.count) combined model(s) are missing and were skipped")
        }
        let cellSize = Self.cellSize(requested: params.resolution, area: area)
        if cellSize > params.resolution * 1.0001 {
            warnings.append(String(format: "Heightmap resolution coarsened to %.4g", cellSize))
        }
        var map = try ReliefHeightmap.rasterize(models, over: area, cellSize: cellSize)
        if let limit = sideLimit {
            ReliefTwoSided.clamp(&map, at: limit)
            metadata["side"] = params.twoSided?.side.rawValue
        }
        if map.maxDepth > job.thickness + 1e-9 {
            warnings.append("Model is deeper than the material thickness")
        }
        if !warnings.isEmpty { metadata["warning"] = warnings.joined(separator: "; ") }
        let clearance = context.coords.job.effectivePlungeGap(default: context.units == .inch ? 0.04 : 1.0)
        let coords = context.coords
        var result: [Toolpath] = []

        if params.roughing.isEnabled {
            let moves = try ReliefRoughing.moves(map: map, region: region, tool: roughTool,
                                             allowance: params.roughing.allowance,
                                             passDepth: params.roughing.passDepth, strategy: params.roughing.strategy,
                                             coords: coords, clearance: clearance, tolerance: context.tolerance)
            if !moves.isEmpty {
                var meta = metadata
                meta["pass"] = "roughing"
                result.append(Toolpath(name: "\(setup.name) (Roughing)", operationID: setup.id, kind: .relief3D,
                                       tool: roughTool, moves: moves, metadata: meta))
            }
        }
        if params.finishing.isEnabled {
            let stepover = max(params.finishing.stepover ?? finishTool.stepover, 1e-4)
            var region = region
            if let previous = restTool {
                // Rest machining: only where the previous (larger) tool could not reach.
                region = ReliefRest.region(map: map, boundary: region, tool: finishTool, previousTool: previous,
                                           margin: max(stepover, finishTool.radius / 2),
                                           // Above the heightmap's own noise (~slope x cell size).
                                           threshold: max(context.units == .inch ? 0.002 : 0.05, map.cellSize / 2),
                                           tolerance: context.tolerance)
                if region.isEmpty, result.isEmpty {
                    throw CAMError.invalidParameter("Nothing left for rest machining: \(previous.name) reaches the whole surface")
                }
            }
            let moves: [Move]
            switch params.finishing.strategy ?? .raster {
            case .raster:
                moves = ReliefFinishing.moves(map: map, region: region, tool: finishTool, stepover: stepover,
                                              angle: params.finishing.angle, coords: coords,
                                              tolerance: context.tolerance, clearance: clearance)
            case .offset, .spiral:
                moves = ReliefFinishing.offsetMoves(map: map, region: region, tool: finishTool, stepover: stepover,
                                                    spiral: params.finishing.strategy == .spiral, coords: coords,
                                                    tolerance: context.tolerance, clearance: clearance)
            }
            if !moves.isEmpty {
                var meta = metadata
                meta["pass"] = "finishing"
                // Group by tool never moves it ahead of the toolpath it rests after (`ToolpathOrdering.canMove`).
                if let source = restSource { meta["restAfter"] = source.setup.id.uuidString }
                result.append(Toolpath(name: "\(setup.name) (Finishing)", operationID: setup.id, kind: .relief3D,
                                       tool: finishTool, moves: moves, metadata: meta))
            }
        }
        guard !result.isEmpty else { throw CAMError.noGeometry }
        return result
    }

    /// Requested cell size, coarsened if needed so the grid stays well under the cell cap.
    static func cellSize(requested: Double, area: Rect2) -> Double {
        let r = max(requested, 1e-6)
        let budget = Double(ReliefHeightmap.maxCells) / 2
        let needed = (area.width * area.height / budget).squareRoot()
        return max(r, needed)
    }
}

extension Relief3DOperation {
    /// The earlier finish this rest pass follows (nil without rest machining). Throws, so a rest pass whose source is
    /// unknown, gone, off, later in the program, not a 3D finish, or on another model or side never falls back to
    /// machining the whole area with the small tool.
    func restSource(in context: CAMContext) throws -> Relief3DOperation? {
        guard let rest = params.finishing.rest else { return nil }
        guard case .operation(let id) = rest else {
            throw CAMError.invalidParameter("Rest after: choose the toolpath this rests after")
        }
        let flat = context.operations.flatMap { op -> [AnyOperation] in
            if case .merge(let m) = op { return m.params.children }
            return [op]
        }
        guard let i = flat.firstIndex(where: { $0.id == id }) else {
            throw CAMError.invalidParameter("Rest after: the toolpath it rests after was deleted")
        }
        let name = flat[i].setup.name
        guard case .relief3D(let source) = flat[i], source.params.finishing.isEnabled else {
            throw CAMError.invalidParameter("Rest after \"\(name)\": that toolpath is not a 3D finish")
        }
        guard source.setup.isEnabled else { throw CAMError.invalidParameter("Rest after \"\(name)\": that toolpath is off") }
        if let me = flat.firstIndex(where: { $0.id == setup.id }), me < i {
            throw CAMError.invalidParameter("Rest after \"\(name)\": that toolpath is after this one")
        }
        guard source.params.modelID == params.modelID, source.params.twoSided?.side == params.twoSided?.side else {
            throw CAMError.invalidParameter("Rest after \"\(name)\": that toolpath cuts another model or side")
        }
        return source
    }
}
