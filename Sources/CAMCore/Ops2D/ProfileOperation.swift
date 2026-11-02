import CADCore
import Foundation

/// Profile: offset outside/inside/on the vector, multi-pass, climb/conventional, tabs, ramps, lead-in, allowance.
public struct ProfileOperation: ToolpathOperation {
    public static let kind = OperationKind.profile
    public var setup: OperationSetup
    public var params: ProfileParameters

    public init(setup: OperationSetup, params: ProfileParameters = ProfileParameters()) {
        self.setup = setup
        self.params = params
    }

    public func generate(in context: CAMContext) throws -> [Toolpath] {
        let tool = try context.tool(setup.toolID)
        let shapes = context.shapes(for: setup)
        guard !shapes.isEmpty else { throw CAMError.noGeometry }
        try params.depth.validatePassDepth(toolStepdown: tool.stepdown)
        let passes = params.depth.passDepths(toolStepdown: tool.stepdown)
        guard !passes.isEmpty else { throw CAMError.invalidParameter("Cut depth must be deeper than start depth") }
        let tol = context.tolerance

        let flat = ShapeGeometry.flattened(shapes, tolerance: tol)
        let vectors = flat.filter(\.isClosed)
        let closed = vectors.map(\.points), open = flat.filter { !$0.isClosed }.map(\.points)
        let lastPass = effectiveLastPass(tolerance: tol)
        let finalOffset = tool.radius + params.allowance
        let roughOffset = finalOffset + (lastPass?.allowance ?? 0)
        let plan = ProfileGeometry.loops(closed: closed, side: params.side, offset: roughOffset,
                                         direction: params.direction, tolerance: tol, join: join)
        let finishPlan = lastPass.map {
            ProfileGeometry.loops(closed: closed, side: params.side, offset: finalOffset,
                                  direction: $0.reverseDirection ? params.direction.reversed : params.direction,
                                  tolerance: tol, join: join)
        }
        var chains = plan.chains
        var openOffsetFailures = 0
        let openSide = params.openVectorSide ?? .on
        for line in open {
            if openSide == .on {
                chains.append(Chain2D(points: line, isClosed: false))
            } else if let shifted = OpenOffset.oneSided(line, distance: finalOffset, left: openSide == .left, tolerance: tol) {
                chains.append(Chain2D(points: shifted, isClosed: false))
            } else {
                openOffsetFailures += 1
                chains.append(Chain2D(points: line, isClosed: false))
            }
        }
        guard !chains.isEmpty || !(finishPlan?.chains.isEmpty ?? true) else {
            throw CAMError.invalidGeometry("The tool does not fit inside the selected vectors")
        }

        let coords = context.coords
        let home = coords.materialXY(fromMachine: context.document.job.home)
        var builder = ToolpathBuilder(coords: coords, tool: tool, units: context.units, tolerance: tol,
                                      fitArcs: params.preferArcs)
        let sourceStarts = closed.compactMap(\.first)
        let shapeLoops = shapes.map { s in s.paths.map { $0.flattened(tolerance: tol) } }
        var cutNotes = CutNotes()
        // Each pass resolves manual anchors against its own loops: an anchor's tab sits where the
        // loop this toolpath would cut for the anchor's part passes it, at this pass's offset. The
        // part is the anchor's vector with every selected closed vector whose offset at that pass
        // joins it (a hole drawn as its own shape, two shapes that overlap, two parts closer than
        // the tool), offset together, so the loop is the one the toolpath cuts. For the grouping
        // each vector offsets alone on the side its nesting in the selection puts it, as the
        // even-odd plan does.
        let manual = params.tabs.isEnabled && !(params.tabs.manualTabs ?? []).isEmpty
        let holes = manual ? Polygon2D.holes(in: closed, tolerance: tol) : []
        var vectorIndex: [UUID: [Int: Int]] = [:]
        for (i, v) in vectors.enumerated() { vectorIndex[v.shapeID, default: [:]][v.pathIndex] = i }
        func ownLoops(at offset: Double) -> (TabAnchor) -> TabAnchors.OwnLoops {
            // The offset the part's loops stand off by: none for a cut on the line, and none for a
            // negative allowance beyond the tool radius (ProfileGeometry clamps it the same way).
            let offset = params.side == .on ? 0 : max(offset, 0)
            let none = TabAnchors.OwnLoops(outline: [], part: [], offset: 0, cut: false)
            guard manual else { return { _ in none } }
            let grow: Double = params.side == .outside ? offset : params.side == .inside ? -offset : 0
            // Every vector is offset the same way for the grouping: a hole always overlaps the vector it is in as
            // drawn, so which way its own offset runs never decides whether two loops are one part.
            let parts = Polygon2D.parts(of: closed, offsets: closed.map { _ in grow }, join: join, tolerance: tol)
            // What an anchor is judged against depends on its part, not on the vector it sits on, so every
            // anchored vector of a part shares one set of outline and loops (a frame with a hundred holes
            // drawn as their own shapes would otherwise offset the whole part once per vector, issue #53).
            struct PartLoops {
                var outline: [ArcLengthChain]
                var part: [ArcLengthChain]
                var cut: Bool
            }
            var memo: [Int: PartLoops] = [:]
            func loops(ofPart p: Int) -> PartLoops {
                if let known = memo[p] { return known }
                let part = closed.indices.filter { parts[$0] == p }.map { closed[$0] }
                let loops = ProfileGeometry.loops(closed: part, side: params.side, offset: offset, direction: params.direction,
                                                  tolerance: tol, join: join).chains
                // A cut on the line follows each vector as drawn; the others cut the even-odd region.
                let outline = params.side == .on ? part : Polygon2D.region(fromLoops: part)
                // A loop only counts as cut when it leaves something to hold: tool-centre loops narrower than the
                // tool (the slivers a wall thinner than twice the offset leaves at its corners) are swept away
                // by their own groove, and no part comes free along them (issue #48).
                let holdsSomething = loops.contains { loop in
                    let ring = PathGeometry.area(loop.points) < 0 ? loop.points.reversed() : loop.points
                    return !GeomKernel.offset([Array(ring)], by: -tool.radius, join: join, arcTolerance: tol).isEmpty
                }
                let made = PartLoops(outline: outline.map { ArcLengthChain(Chain2D(points: $0, isClosed: true)) },
                                     part: loops.map { ArcLengthChain($0) },
                                     cut: !loops.isEmpty && (params.side == .on || holdsSomething))
                memo[p] = made
                return made
            }
            return { anchor in
                guard let k = vectorIndex[anchor.shapeID]?[anchor.pathIndex] else { return none }
                let shared = loops(ofPart: parts[k])
                let survives = grow == 0 || !GeomKernel.offset([closed[k]], by: holes[k] ? -grow : grow, join: join, arcTolerance: tol).isEmpty
                return TabAnchors.OwnLoops(outline: shared.outline, part: shared.part, offset: offset, cut: shared.cut && survives)
            }
        }
        let rough = cutLoops(chains, passes: passes, from: home, tool: tool, wasteRegion: plan.wasteRegion,
                             sourceStarts: sourceStarts, shapeLoops: shapeLoops, ownLoops: ownLoops(at: roughOffset),
                             context: context, builder: &builder, cutNotes: &cutNotes)
        var ignoredAnchors = rough.anchors?.ignored ?? 0
        var unheldOnRoughing = 0
        if let lastPass, let finishPlan {
            // Last pass: removes the side allowance the roughing passes left on the wall. Its loops
            // start wherever the roughing ended, so automatic tabs would land elsewhere and the lap
            // would cut the roughing tabs away; the roughing tab positions are reused instead. A
            // loop the roughing offset swallowed has none to inherit and lays out its own. The last
            // pass sees every loop the roughing pass saw and more, so it decides which anchors
            // were ignored.
            let finishPasses = lastPass.fullDepth ? [params.depth.cutDepth] : passes
            let finish = cutLoops(finishPlan.chains, passes: finishPasses, from: builder.position?.xy ?? home, tool: tool,
                                  wasteRegion: finishPlan.wasteRegion, sourceStarts: sourceStarts, shapeLoops: shapeLoops,
                                  ownLoops: ownLoops(at: finalOffset),
                                  // The allowance the roughing loops actually stand off by: a negative
                                  // allowance beyond the tool radius clamps either offset at zero.
                                  roughing: (tabs: rough.placed, loops: plan.chains.map { ArcLengthChain($0) },
                                             allowance: max(roughOffset, 0) - max(finalOffset, 0)),
                                  context: context, builder: &builder, cutNotes: &cutNotes)
            ignoredAnchors = finish.anchors?.ignored ?? 0
            // An anchor the roughing pass could not place while the loop of its own vector was in
            // that pass's toolpath (its stretch filled by the larger offset while the loop survives
            // elsewhere, or trimmed beyond reach) leaves the part cut through there before the last
            // pass holds it. A vector the roughing offset swallowed whole was not cut by it.
            if let r = rough.anchors, let f = finish.anchors {
                unheldOnRoughing = zip(zip(r.placed, r.cut), f.placed).filter { !$0.0 && $0.1 && $1 }.count
            }
        }
        var meta: [String: String] = [:]
        var warnings: [String] = []
        if cutNotes.shortLoops > 0 {
            warnings.append("\(cutNotes.shortLoops) loop(s) got fewer tabs than asked (too short, or anchors too close; "
                + "fewest placed: \(cutNotes.fewest)); the part may come free")
        }
        if cutNotes.lostOnLastPass > 0 {
            warnings.append("tabs did not carry to the last pass on \(cutNotes.lostOnLastPass) loop(s); the part may come free")
        }
        if unheldOnRoughing > 0 {
            warnings.append("\(unheldOnRoughing) tab anchor(s) hold only on the last pass; the roughing passes cut through there and the part may come free")
        }
        if ignoredAnchors > 0 {
            warnings.append("\(ignoredAnchors) tab anchor(s) ignored: not on a stretch of a closed vector this toolpath cuts, "
                + "or the vector is gone; no tab placed for them")
        }
        let dropped = finishPlan?.droppedLoops ?? plan.droppedLoops
        if dropped > 0 { warnings.append("\(dropped) vector(s) too small for the tool") }
        if openOffsetFailures > 0 {
            warnings.append("\(openOffsetFailures) open vector(s) could not be offset to the \(openSide.rawValue) and were cut on the line")
        }
        if params.side != .on && !open.isEmpty && openSide == .on {
            warnings.append("\(open.count) open vector(s) cut on the line (close them to cut \(params.side == .outside ? "outside" : "inside"))")
        }
        if cutNotes.steepRamp { warnings.append(PassShaping.steepRampWarning(params.ramp)) }
        if !warnings.isEmpty { meta["warning"] = warnings.joined(separator: "; ") }
        return [Toolpath(name: setup.name, operationID: setup.id, kind: .profile, tool: tool,
                         moves: builder.finish(), metadata: meta)]
    }

    /// Corner treatment of the offset loops: squared off when sharp corners are asked for.
    private var join: GeomKernel.Join { params.sharpCorners == true ? .miter(limit: ProfileGeometry.sharpMiterLimit) : .round }

    /// The last-pass settings when they apply (closed vectors cut outside/inside, allowance > 0).
    func effectiveLastPass(tolerance: Double) -> ProfileLastPass? {
        guard let lp = params.lastPass, params.side != .on, lp.allowance > tolerance else { return nil }
        return lp
    }

    /// What the cut could not do as asked: loops that got fewer tabs than asked (too short to hold
    /// them apart, or manual anchors that overlapped) and the fewest any of them got; last-pass loops
    /// whose roughing loop had tabs that did not reach them; and whether any pass's ramp went down
    /// steeper than its maximum angle (issue #124).
    private struct CutNotes {
        var shortLoops = 0, fewest = Int.max, lostOnLastPass = 0
        var steepRamp = false
    }

    /// Orders `chains` (inner loops first) from `start` and cuts each through `passes`, resolving
    /// manual anchors against these loops through `ownLoops` (what this pass would cut for the
    /// anchor's part). Returns the material-frame centre of every tab it placed and what became of
    /// each anchor (nil with no manual anchors). On the last pass, `roughing` gives the roughing pass's tabs and loops: a
    /// loop whose roughing loop (the one `allowance` farther out) had tabs takes those that project
    /// onto it, and is reported when none do, since the roughing pass has already cut through
    /// beside them; a loop the roughing offset swallowed lays out its own tabs and counts what it
    /// could not do, which the roughing pass did for every loop it had.
    private func cutLoops(_ chains: [Chain2D], passes: [Double], from start: Vec2, tool: Tool, wasteRegion: WasteSide,
                          sourceStarts: [Vec2], shapeLoops: [[[Vec2]]], ownLoops: (TabAnchor) -> TabAnchors.OwnLoops,
                          roughing: (tabs: [Vec2], loops: [ArcLengthChain], allowance: Double)? = nil, context: CAMContext,
                          builder: inout ToolpathBuilder, cutNotes: inout CutNotes) -> (placed: [Vec2], anchors: TabAnchors.Resolution?) {
        let tol = context.tolerance
        let startPoint = params.startPoint ?? .nearest
        var ordered = ProfileOrdering.ordered(chains, by: params.order ?? .nearest, from: start, shapeLoops: shapeLoops,
                                              allowReverse: startPoint != .vectorStart, tolerance: tol)
        ordered = ordered.map { StartPoints.rotate($0, to: startPoint, sourceStarts: sourceStarts, tolerance: tol) }
        var manualCenters: [[Double]]?
        var resolved: TabAnchors.Resolution?
        if params.tabs.isEnabled, let anchors = params.tabs.manualTabs {
            resolved = TabAnchors.centers(for: anchors, loops: ordered.map { ArcLengthChain($0) }, shapeIDs: Set(setup.shapeIDs),
                                          ownLoops: ownLoops, document: context.document, tolerance: tol)
            manualCenters = resolved?.centers
        }
        // Which roughing loop is each last-pass loop's: offsetting all the last-pass loops together by
        // the allowance rebuilds the roughing loops (merged where the roughing offset merged them),
        // and the roughing loop that runs through the rebuilt point one allowance across from a
        // loop's edge is its own. Only with tabs on, which is all it serves: it walks every loop.
        var rebuilt: [ArcLengthChain] = [], boxes: [Rect2] = []
        if params.tabs.isEnabled, let roughing {
            rebuilt = ProfileGeometry.loops(closed: ordered.filter(\.isClosed).map(\.points), side: params.side,
                                            offset: roughing.allowance, direction: params.direction, tolerance: tol, join: join)
                .chains.map { ArcLengthChain($0) }
            boxes = rebuilt.map { Rect2(points: $0.chain.points).insetBy(-(roughing.allowance + 4 * tol + 1e-6)) }
        }
        var placed: [Vec2] = []
        for (i, chain) in ordered.enumerated() {
            var centers = manualCenters?[i]
            var counts = true
            if params.tabs.isEnabled, let roughing, chain.isClosed {
                let alc = ArcLengthChain(chain)
                let within = roughing.allowance + 4 * tol + 1e-6
                // The rebuilt point across from the first edge midpoint that has one: a stretch the
                // roughing offset swallowed (a merge, a collapse) has nothing within an allowance.
                var across: Vec2?
                let walk = chain.walk
                probes: for (a, b) in zip(walk, walk.dropFirst()) {
                    let m = (a + b) * 0.5
                    for (l, box) in zip(rebuilt, boxes) where box.contains(m) {
                        let pr = l.project(m)
                        if pr.distance <= within { across = l.point(at: pr.s); break probes }
                    }
                }
                let roughLoops = across.map { q in roughing.loops.filter { $0.project(q).distance <= 8 * tol + 1e-6 } } ?? []
                counts = roughLoops.isEmpty
                // A loop no manual anchor resolved to on this pass is treated like an automatic one: the
                // anchors can land on different loops on the two passes (where the roughing offset trims an
                // anchor's stretch to a corner of one piece and the last pass reaches another), and the
                // roughing tab on this one must not be cut away unseen (issue #49).
                if centers?.isEmpty ?? true, !roughLoops.isEmpty {
                    let inherited = roughing.tabs.compactMap { p -> Double? in
                        let pr = alc.project(p)
                        return pr.distance <= within ? pr.s : nil
                    }
                    centers = inherited
                    if inherited.isEmpty, roughing.tabs.contains(where: { p in roughLoops.contains { $0.project(p).distance <= within } }) {
                        cutNotes.lostOnLastPass += 1
                    }
                }
            }
            placed += cut(chain, passes: passes, tool: tool, wasteRegion: wasteRegion, manualTabs: centers,
                          layingOut: counts, builder: &builder, tolerance: tol, cutNotes: &cutNotes)
        }
        return (placed, resolved)
    }

    /// `manualTabs`: tab centres (loop parameters) for this loop (nil = automatic layout);
    /// `layingOut` is false for a last-pass loop whose roughing loop was counted already, so no
    /// loop is counted twice. Returns the material-frame centre of each tab used.
    private func cut(_ chain: Chain2D, passes: [Double], tool: Tool, wasteRegion: WasteSide, manualTabs: [Double]?,
                     layingOut: Bool, builder: inout ToolpathBuilder, tolerance tol: Double,
                     cutNotes: inout CutNotes) -> [Vec2] {
        let alc = ArcLengthChain(chain)
        guard alc.length > tol else { return [] }
        let start = params.depth.startDepth
        if !chain.isClosed {
            // Open vectors: cut on the line, alternating direction each pass.
            var forward = true
            var prev = start
            let backward = ArcLengthChain(chain.reversed())
            for d in passes {
                let pass = PassShaping.pass(on: forward ? alc : backward, s0: 0, fromDepth: prev, toDepth: d,
                                            ramp: params.ramp)
                if pass.isSteeperThanMaxAngle { cutNotes.steepRamp = true }
                builder.cutChain(pass.points)
                prev = d
                forward.toggle()
            }
            return []
        }

        var tabs: TabLayout?
        if params.tabs.isEnabled {
            let layout = manualTabs.map {
                TabLayout(loopLength: alc.length, centers: $0, settings: params.tabs, toolDiameter: tool.diameter,
                          cutDepth: params.depth.cutDepth)
            } ?? TabLayout(loopLength: alc.length, settings: params.tabs, toolDiameter: tool.diameter, cutDepth: params.depth.cutDepth)
            if layingOut, layout.centers.count < layout.requestedCount {
                cutNotes.shortLoops += 1
                cutNotes.fewest = min(cutNotes.fewest, layout.centers.count)
            }
            tabs = layout
        }
        let useLeads = params.lead.type != .none && params.lead.distance > 0
        var ramp = params.ramp
        if useLeads { ramp.isEnabled = false }
        let overcut = max(0, params.lead.overcut)
        var s0 = 0.0
        var prev = start
        for (k, d) in passes.enumerated() {
            let isLast = k == passes.count - 1
            var pass = PassShaping.pass(on: alc, s0: s0, fromDepth: prev, toDepth: d, ramp: ramp,
                                        overcut: overcut, spiralFinish: isLast)
            if pass.isSteeperThanMaxAngle { cutNotes.steepRamp = true }
            if let tabs { pass = tabs.apply(to: pass, chain: alc) }
            var pts = pass.points
            if useLeads {
                let t0 = alc.tangent(at: s0), t1 = alc.tangent(at: pass.endS)
                let isWaste = { (p: Vec2) in wasteRegion.isWaste(p, slack: tol) }
                let inPts = Leads.safeLeadIn(to: alc.point(at: s0), tangent: t0,
                                             waste: wasteRegion.normal(at: alc.point(at: s0), tangent: t0),
                                             settings: params.lead, tolerance: tol, isWaste: isWaste)
                let endP = alc.point(at: pass.endS)
                let outPts = Leads.safeLeadOut(from: endP, tangent: t1,
                                               waste: wasteRegion.normal(at: endP, tangent: t1),
                                               settings: params.lead, tolerance: tol, isWaste: isWaste)
                pts = inPts.map { CutPoint($0, depth: d) } + pts + outPts.map { CutPoint($0, depth: d) }
            }
            // With leads every pass re-enters at the same lead-in, already cut to `prev`.
            builder.cutChain(pts, clearedDepth: useLeads && k > 0 ? prev : 0)
            prev = d
            // Without leads the next pass starts where this one ended (no retract).
            if !useLeads { s0 = pass.endS }
        }
        return tabs?.centers.map { alc.point(at: $0) } ?? []
    }
}

extension CutDirection {
    /// The opposite cutting direction.
    public var reversed: CutDirection { self == .climb ? .conventional : .climb }
}

/// Tells which side of a toolpath loop is waste (for lead-ins).
public struct WasteSide: Sendable {
    /// Tool-centre region (even-odd loops).
    public var region: [[Vec2]]
    /// Waste lies inside `region` (inside profiles) or outside it (outside / on).
    public var wasteInside: Bool
    public var probe: Double

    /// Unit normal pointing to the waste at `p` for travel direction `t`.
    public func normal(at p: Vec2, tangent t: Vec2) -> Vec2 {
        let left = t.perpendicular
        let leftInside = Polygon2D.regionContains(region, p + left * probe)
        return leftInside == wasteInside ? left : -left
    }

    /// True when a tool centre at `p` stays on the waste side (no gouge), allowing `slack`
    /// of numerical error at the loop itself.
    public func isWaste(_ p: Vec2, slack: Double) -> Bool {
        if Polygon2D.regionContains(region, p) == wasteInside { return true }
        return region.contains { Polygon2D.distance(from: p, toLoop: $0) <= slack }
    }
}

/// Profile toolpath loops from closed vectors.
public enum ProfileGeometry {
    public struct Plan: Sendable {
        public var chains: [Chain2D]
        public var wasteRegion: WasteSide
        /// Input loops that vanished (tool too large for an inside cut).
        public var droppedLoops: Int
    }

    /// Offsets the even-odd region of `closed` by `offset` (outside grows, inside shrinks,
    /// on = none) and orients the loops for the cut direction (climb on a clockwise spindle
    /// keeps the finished part on the right of travel).
    /// Miter limit (multiple of the offset) for sharp corners; sharper corners are squared off there.
    public static let sharpMiterLimit = 4.0

    public static func loops(closed: [[Vec2]], side: ProfileSide, offset: Double, direction: CutDirection,
                             tolerance: Double, join: GeomKernel.Join = .round) -> Plan {
        let region = Polygon2D.region(fromLoops: closed)
        var loops: [[Vec2]]
        switch side {
        case .on:
            // Each vector as drawn (no union), oriented like a region's loops: outer loops
            // counter-clockwise, holes clockwise, so a ring's hole keeps the part on the same side of
            // travel as its outer edge.
            loops = zip(closed, Polygon2D.holes(in: closed, tolerance: tolerance)).map { loop, hole in
                (Polygon2D.signedArea(loop) < 0) == hole ? loop : loop.reversed()
            }
        case .outside:
            loops = GeomKernel.offset(region, by: max(offset, 0), join: join, arcTolerance: tolerance)
        case .inside:
            loops = GeomKernel.offset(region, by: -max(offset, 0), join: join, arcTolerance: tolerance)
        }
        loops = loops.map { Polygon2D.deduplicated($0, closed: true, tolerance: tolerance * 1e-3) }.filter { $0.count > 2 }
        // Loops have the region on the left (outer CCW, holes CW).
        // Part on the left for outside/on cuts, on the right for inside cuts.
        let partOnLeft = side != .inside
        let climb = direction == .climb
        // Climb ⇒ part on the right of travel.
        let reverse = partOnLeft == climb
        let chains = loops.map { Chain2D(points: reverse ? Array($0.reversed()) : $0, isClosed: true) }
        let dropped = side == .inside ? max(0, region.count - loops.count) : 0
        let wasteRegion = WasteSide(region: side == .on ? region : loops, wasteInside: side == .inside,
                                    probe: max(tolerance * 4, 1e-4))
        return Plan(chains: chains, wasteRegion: wasteRegion, droppedLoops: dropped)
    }
}
