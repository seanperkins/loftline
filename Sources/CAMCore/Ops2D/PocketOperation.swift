import CADCore
import Foundation

/// Pocket: offset or raster area clearing, optional separate clearance tool.
public struct PocketOperation: ToolpathOperation {
    public static let kind = OperationKind.pocket
    public var setup: OperationSetup
    public var params: PocketParameters

    public init(setup: OperationSetup, params: PocketParameters = PocketParameters()) {
        self.setup = setup
        self.params = params
    }

    public func generate(in context: CAMContext) throws -> [Toolpath] {
        let tool = try context.tool(setup.toolID)
        let shapes = context.shapes(for: setup)
        guard !shapes.isEmpty else { throw CAMError.noGeometry }
        let tol = context.tolerance
        let closed = ShapeGeometry.loops(of: shapes, tolerance: tol).closed
        guard !closed.isEmpty else { throw CAMError.invalidGeometry("Pocketing needs closed vectors") }
        let region = Polygon2D.region(fromLoops: closed)
        guard !region.isEmpty else { throw CAMError.invalidGeometry("Selected vectors enclose no area") }
        let start = context.coords.materialXY(fromMachine: context.document.job.home)

        let (clearanceTools, skipped) = try usableClearanceTools(finish: tool, context: context)

        var toolpaths: [Toolpath] = []
        var restAfter: Double?
        var leftUncut = false
        var steepRamp = false
        for (i, big) in clearanceTools.enumerated() {
            let planner = try makePlanner(region: region, tool: big, tolerance: tol)
            // The first tool clears everything; each later one only what the previous could not reach.
            var stageUncut = false
            let groups: [[Chain2D]]
            if let rest = restAfter {
                let report = planner.restClearingReport(clearanceRadius: rest, from: start, fullWalls: false)
                stageUncut = report.uncoveredArea > planner.coverageSlack * planner.coverageSlack
                groups = report.groups
            } else {
                groups = clearing(planner, from: start, leftUncut: &stageUncut)
            }
            // Floor this tool could reach and left uncut is reported even when it cut nothing at all.
            if stageUncut { leftUncut = true }
            guard !groups.isEmpty else { continue }
            let label = clearanceTools.count == 1 ? "clearance" : "clearance \(i + 1)"
            let clearance = try emit(groups, planner: planner, tool: big, context: context, name: "\(setup.name) (\(label))")
            toolpaths.append(clearance.toolpath)
            if clearance.steepRamp { steepRamp = true }
            // Later tools take everything this one reached as cleared, so a tool that left floor uncut
            // does not hand over (the floor it missed stays in the next tool's job, and is reported).
            if !stageUncut { restAfter = big.radius }
        }
        let planner = try makePlanner(region: region, tool: tool, tolerance: tol)
        var finishUncut = false
        let groups: [[Chain2D]]
        if let rest = restAfter {
            let report = planner.restClearingReport(clearanceRadius: rest, from: start)
            finishUncut = report.uncoveredArea > planner.coverageSlack * planner.coverageSlack
            groups = report.groups
        } else {
            groups = clearing(planner, from: start, leftUncut: &finishUncut)
        }
        if finishUncut { leftUncut = true }
        guard !groups.isEmpty else {
            throw CAMError.invalidGeometry("The tool does not fit inside the selected vectors")
        }
        let emitted = try emit(groups, planner: planner, tool: tool, context: context, name: setup.name)
        var finish = emitted.toolpath
        if emitted.steepRamp { steepRamp = true }
        var warnings: [String] = []
        let missed = planner.unreachableComponents
        if missed > 0 { warnings.append("\(missed) region(s) too small for the tool") }
        if leftUncut {
            warnings.append("floor the tool can reach is left uncut at this stepover; use a smaller stepover")
        }
        if skipped > 0 { warnings.append("\(skipped) clearance tool(s) ignored (each must be smaller than the one before and larger than the finish tool)") }
        // Reported once, here: a second "warning" key on a clearance toolpath would collide in the
        // operation editor's metadata list.
        if steepRamp { warnings.append(PassShaping.steepRampWarning(params.ramp)) }
        if !warnings.isEmpty { finish.metadata["warning"] = warnings.joined(separator: "; ") }
        toolpaths.append(finish)
        return toolpaths
    }

    /// Clearance tools that will cut, in order: each must be smaller than the previous one and
    /// larger than the finish tool. Returns them plus the number skipped.
    func usableClearanceTools(finish: Tool, context: CAMContext) throws -> ([Tool], Int) {
        let tol = context.tolerance
        var used: [Tool] = []
        var skipped = 0
        for id in params.clearanceTools where id != setup.toolID {
            let t = try context.tool(id)
            let limit = used.last?.diameter ?? .infinity
            if t.diameter > finish.diameter + tol && t.diameter < limit - tol {
                used.append(t)
            } else {
                skipped += 1
            }
        }
        return (used, skipped)
    }

    private func makePlanner(region: [[Vec2]], tool: Tool, tolerance: Double) throws -> PocketPlanner {
        guard tool.diameter > 0 else { throw CAMError.invalidParameter("Tool diameter must be positive") }
        let step = min(max(tool.stepover, 0), tool.diameter * 0.95)
        guard step > tolerance else { throw CAMError.invalidParameter("Tool stepover must be positive") }
        return PocketPlanner(region: region, toolRadius: tool.radius, stepover: step, allowance: params.allowance,
                             tolerance: tolerance, direction: params.direction)
    }

    /// The cutting order for `planner`'s region; `leftUncut` is set when an offset pocket could not finish covering
    /// the floor the tool can reach (more than a sliver of the slack's width is still farther than the slack from
    /// every cut).
    private func clearing(_ planner: PocketPlanner, from start: Vec2, leftUncut: inout Bool) -> [[Chain2D]] {
        switch params.strategy {
        case .offset:
            let report = planner.offsetClearingReport(from: start)
            leftUncut = report.uncoveredArea > planner.coverageSlack * planner.coverageSlack
            return report.groups
        case .raster(let angle, let profilePass):
            return planner.rasterClearing(angle: angle, profilePass: profilePass,
                                          profileFirst: params.profilePassFirst == true, from: start)
        }
    }

    /// Cuts every component through all depth passes, linking chains at depth when the
    /// connecting move stays inside the tool-centre region.
    /// `steepRamp`: some pass's ramp went down steeper than its maximum angle (issue #124).
    private func emit(_ groups: [[Chain2D]], planner: PocketPlanner, tool: Tool, context: CAMContext,
                      name: String) throws -> (toolpath: Toolpath, steepRamp: Bool) {
        try params.depth.validatePassDepth(toolStepdown: tool.stepdown)
        let passes = params.depth.passDepths(toolStepdown: tool.stepdown)
        guard !passes.isEmpty else { throw CAMError.invalidParameter("Cut depth must be deeper than start depth") }
        let tol = context.tolerance
        var builder = ToolpathBuilder(coords: context.coords, tool: tool, units: context.units, tolerance: tol)
        var steepRamp = false
        let linker = RegionLinker(region: planner.centerRegion, maxLength: 2 * tool.diameter, tolerance: tol)
        for chains in groups {
            var prev = params.depth.startDepth
            for (k, d) in passes.enumerated() {
                for (i, chain) in chains.enumerated() {
                    let alc = ArcLengthChain(chain)
                    if i > 0, let cur = builder.position, abs(cur.depth - d) < 1e-9,
                       let link = linker.link(from: cur.xy, to: chain.start) {
                        let lap = PassShaping.pass(on: alc, s0: 0, fromDepth: d, toDepth: d, ramp: RampSettings())
                        builder.feed(to: link.map { CutPoint($0, depth: d) } + lap.points)
                    } else {
                        // Everything in the region is already cleared to the previous pass depth.
                        let cleared = k == 0 ? 0 : prev
                        let pass = PassShaping.pass(on: alc, s0: 0, fromDepth: k == 0 ? params.depth.startDepth : prev,
                                                    toDepth: d, ramp: params.ramp)
                        if pass.isSteeperThanMaxAngle { steepRamp = true }
                        builder.cutChain(pass.points, clearedDepth: cleared)
                    }
                }
                prev = d
            }
        }
        return (Toolpath(name: name, operationID: setup.id, kind: .pocket, tool: tool, moves: builder.finish()), steepRamp)
    }
}
