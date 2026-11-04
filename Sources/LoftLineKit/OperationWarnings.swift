import CADCore
import CAMCore
import Foundation
import PostCore

/// Mistakes in a toolpath's settings that the export validator would only catch at the last step, shown in the
/// toolpath form as soon as they are made (issue #24): a cut deeper than the stock allows, a tool with no feed,
/// plunge or diameter, a tab as tall as the cut, a spindle speed the post cannot run. (A cut deeper than the
/// tool's flutes has its own note under the cut depth, `OperationHints.fluteLengthProblem`.)
public enum OperationWarnings {
    /// The warnings for `op` as the form would show them. `library` is the library the document cuts with (the
    /// project's snapshot included), `profile` the post in force with the job's machine limits applied, `units`
    /// the document's.
    public static func make(_ op: AnyOperation, project: LoftLineProject, library: ToolLibrary, profile: PostProfile,
                     units: LengthUnit) -> [String] {
        var out: [String] = []
        let job: JobSetup
        if case .success(let j) = project.machiningJob(for: op) { job = j } else { job = project.document.job }
        guard let stored = library.tool(id: op.setup.toolID) else { return out }
        var tool = stored.forMaterial(job.material).converted(to: units)
        if let o = op.setup.toolOverride { tool = o.applied(to: tool) }
        let u = units.abbreviation

        if op.kind != .merge {
            if primaryToolCuts(op) { out += toolProblems(tool, profile: profile, overridable: true) }
            // The other tools the operation cuts with (clearance, roughing) are judged the same way, by name.
            var seen: Set<UUID> = [op.setup.toolID]
            for id in secondaryToolIDs(of: op, primary: tool, library: library, material: job.material, units: units)
            where seen.insert(id).inserted {
                guard let other = library.tool(id: id)?.forMaterial(job.material).converted(to: units) else { continue }
                out += toolProblems(other, profile: profile, overridable: false).map { "\(other.name): \($0)" }
            }
        }

        if let depth = cutDepth(of: op, tool: tool), op.setup.projectOntoModelID == nil {
            // The validator's rule: the material bottom plus what the machine lets a cut into the spoilboard.
            let into = profile.limits.maxSpoilboardCut * profile.units.factor(to: units)   // as `MotionChecker` has it, sign and all
            let allowed = job.thickness + into
            if depth > allowed + CAMContext.defaultTolerance(units) {
                let past = RulerTicks.label((abs(depth - job.thickness) * 10000).rounded() / 10000)
                let rule = into >= 0 ? "the machine allows \(RulerTicks.label(into)) \(u) into the spoilboard"
                                     : "the machine wants cuts to stop \(RulerTicks.label(-into)) \(u) above the bottom"
                out.append("The cut is \(past) \(u) \(depth >= job.thickness ? "below" : "above") the material bottom "
                           + "(\(RulerTicks.label(job.thickness)) \(u) thick); \(rule).")
            }
        }

        if case .holeMill(let h) = op {
            out += holeMillProblems(h, in: project, library: library, tool: tool, job: job, units: units)
        }

        // Tabs that the generator will place: on, and on a closed vector it cuts (an open vector has none, and a manual
        // anchor counts only on a selected closed vector that still exists).
        if case .profile(let p) = op, p.params.tabs.isEnabled, tabsWillBePlaced(p, in: project.document) {
            let span = p.params.depth.cutDepth - p.params.depth.startDepth
            if p.params.tabs.thickness >= span - CAMContext.defaultTolerance(units), span > 0 {
                out.append("The tab height (\(RulerTicks.label(p.params.tabs.thickness)) \(u)) is as tall as the cut "
                           + "(\(RulerTicks.label(span)) \(u) deep): tabs this tall leave nothing cut where they sit.")
            }
        }
        return out
    }

    /// Hole milling: a through hole bored with a helix leaves a free slug inside it, and a thread assumes a pilot
    /// hole. Both depend on what the job does at the same centre, so they are judged here, not by the generator.
    public static func holeMillProblems(_ op: HoleMillOperation, in project: LoftLineProject, library: ToolLibrary, tool: Tool,
                                 job: JobSetup, units: LengthUnit) -> [String] {
        let tol = 3 * CAMContext.defaultTolerance(units)
        let u = units.abbreviation
        var holes = HoleMillOperation.holes(project.document.shapes(ids: op.setup.shapeIDs), tolerance: tol)
        if let d = op.params.holeDiameter { holes = holes.map { HoleMillOperation.Hole(centre: $0.centre, diameter: d) } }
        holes = holes.filter { $0.diameter >= tool.diameter - tol }     // the generator skips the smaller ones
        // Projected onto a 3D model, its depths are measured from the model's surface, which only calculating knows: the
        // slug and the pilot cannot be judged from the settings, and the form says so where either could matter.
        if op.setup.projectOntoModelID != nil {
            let slugPossible = op.params.mode == .helical && holes.contains { $0.diameter - 2 * tool.diameter > tool.diameter + tol }
            let pilotNeeded = op.params.mode == .thread
                && holes.contains { ($0.diameter - tool.diameter) / 2 > CAMContext.defaultTolerance(units) }
            return slugPossible || pilotNeeded
                ? ["This toolpath is projected onto a 3D model, so whether it leaves a free slug (through holes) or has the pilot "
                   + "hole a thread needs cannot be judged from its settings: check it in the 3D preview."]
                : []
        }
        // Every copy of an array is a hole too, at the vector's centre shifted by the copy's offset.
        let copies = op.setup.arrayCopy?.offsets ?? [.zero]
        holes = holes.flatMap { hole in copies.map { HoleMillOperation.Hole(centre: hole.centre + $0, diameter: hole.diameter) } }
        // What runs before this toolpath in the list, on its sheet and side (the others are other programs); a toolpath
        // that is not in the list has nothing before it.
        // (Vectors on several sheets or sides have no sheet or side, and nothing matches that: the toolpath errors anyway.)
        let thisOp = AnyOperation.holeMill(op)
        let sheet = project.sheetID(of: thisOp), side = project.side(of: thisOp)
        let earlier = (project.operations.firstIndex { $0.id == op.setup.id }.map { Array(project.operations.prefix($0)) } ?? [])
            .filter { sheet != nil && side != nil && project.sheetID(of: $0) == sheet && project.side(of: $0) == side }
        /// An earlier toolpath that clears at least `depth` deep and `width` across at `c`, from the material top (a drill,
        /// only, when `drillOnly`): one that starts below the top leaves the material above it for the tool to cut.
        func made(at c: Vec2, depth: Double, width: Double, drillOnly: Bool) -> Bool {
            earlier.contains { other in
                clearing(of: other, at: c, project: project, library: library, material: job.material, units: units,
                         tolerance: tol, drillOnly: drillOnly)
                    .contains { $0.start <= tol && $0.depth >= depth - 1e-6 && $0.width >= width - 1e-6 && $0.depth > $0.start + tol }
            }
        }
        var out: [String] = []
        switch op.params.mode {
        case .thread:
            // The thread mill goes down the middle to the cut depth, so something earlier has to have cleared that far
            // and at least as wide as the tool.
            // (A thread is milled where the generator finds a radius above its own tolerance, not three times it.)
            let generatorTol = CAMContext.defaultTolerance(units)
            let bare = holes.filter {
                ($0.diameter - tool.diameter) / 2 > generatorTol
                    && !made(at: $0.centre, depth: op.params.cutDepth, width: tool.diameter, drillOnly: false)
            }
            if !bare.isEmpty {
                out.append("\(bare.count) hole(s) in thread mode have no pilot hole: no earlier toolpath in the list drills, bores or "
                           + "pockets at the center to the thread's depth and at least as wide as the tool, so the thread mill would "
                           + "plunge into solid material.")
            }
        case .helical:
            // The ring the helix sweeps leaves a core of diameter D - 2d; cut through, it comes loose.
            guard op.params.cutDepth >= job.thickness - tol else { break }
            // Drilled out: an earlier Drill through the material, at least as wide as the slug.
            let slugs = holes.filter { hole in
                let slug = hole.diameter - 2 * tool.diameter
                return slug > tool.diameter + tol
                    && !made(at: hole.centre, depth: job.thickness, width: slug, drillOnly: true)
            }
            if let widest = slugs.map({ $0.diameter - 2 * tool.diameter }).max() {
                out.append("\(slugs.count) through hole(s) leave a free slug up to \(RulerTicks.label((widest * 1000).rounded() / 1000)) \(u) wide "
                           + "inside the helix: it can jam against the tool when it comes loose. Drill the center out first with a "
                           + "Drill toolpath through the material and as wide as the slug, or stop the cut short of the bottom.")
            }
        }
        return out
    }

    /// How deep and how wide across `other` clears material at `c`, or nil when it does not make a hole there: a Drill at
    /// the center (as wide as its tool), unless `drillOnly` also a helical bore there that leaves no core (a hole no wider
    /// than twice its tool; a wider one is only a ring, the middle stays solid) and a pocket whose vectors enclose it
    /// (as wide as the room round `c` that its tool can reach). A profile cuts the perimeter only, so it makes no pilot.
    /// The copies of an array count at their offsets. `start` is the depth the toolpath starts at.
    private static func clearing(of other: AnyOperation, at point: Vec2, project: LoftLineProject, library: ToolLibrary, material: String?,
                                 units: LengthUnit, tolerance tol: Double, drillOnly: Bool) -> [(start: Double, depth: Double, width: Double)] {
        // (A toolpath projected onto a model is cut below the model's surface, not to the depth it states.)
        guard other.setup.isEnabled, other.setup.projectOntoModelID == nil else { return [] }
        // Every copy of an array that reaches the point counts, each by its own width: the first is not the best.
        return (other.setup.arrayCopy?.offsets ?? [.zero]).compactMap { offset in
            clearing(of: other, atOriginal: point - offset, project: project, library: library, material: material,
                     units: units, tolerance: tol, drillOnly: drillOnly)
        }
    }

    private static func clearing(of other: AnyOperation, atOriginal c: Vec2, project: LoftLineProject, library: ToolLibrary, material: String?,
                                 units: LengthUnit, tolerance tol: Double, drillOnly: Bool) -> (start: Double, depth: Double, width: Double)? {
        let shapes = project.document.shapes(ids: other.setup.shapeIDs)
        func otherTool() -> Tool? { library.tool(id: other.setup.toolID)?.forMaterial(material).converted(to: units) }
        /// The room round `c` inside the area the pocket's tool reaches: the vectors' region shrunk by the tool's radius and
        /// the allowance and grown back, twice the distance from `c` to its nearest edge (nil when `c` is outside it).
        func room(tool: Tool?, allowance: Double) -> Double? {
            guard let tool else { return nil }
            let region = Polygon2D.region(fromLoops: ShapeGeometry.loops(of: shapes, tolerance: tol).closed)
            let inset = GeomKernel.offset(region, by: -(tool.radius + allowance), join: .round, arcTolerance: tol)
            let reached = GeomKernel.offset(inset, by: tool.radius, join: .round, arcTolerance: tol)
            guard !reached.isEmpty, Polygon2D.regionContains(reached, c) else { return nil }
            return 2 * (reached.map { Polygon2D.distance(from: c, toLoop: $0) }.min() ?? 0)
        }
        switch other {
        case .drill(let d):
            // The tool at the drill's own center: its width round `c` is less by twice how far off `c` is.
            guard let centre = DrillOperation.holeCentres(shapes, tolerance: tol).first(where: { $0.distance(to: c) <= tol }),
                  let t = otherTool() else { return nil }
            return (d.params.startDepth, d.params.cutDepth, t.diameter - 2 * centre.distance(to: c))
        case .holeMill(let h) where !drillOnly && h.params.mode == .helical:
            guard var hole = HoleMillOperation.holes(shapes, tolerance: tol).first(where: { $0.centre.distance(to: c) <= tol }),
                  let t = otherTool() else { return nil }
            if let d = h.params.holeDiameter { hole.diameter = d }
            guard hole.diameter >= t.diameter - tol, HoleMillOperation.leavesNoCore(hole, tool: t, tolerance: tol) else { return nil }
            return (h.params.startDepth, h.params.cutDepth, hole.diameter - 2 * hole.centre.distance(to: c))
        case .pocket(let p) where !drillOnly:
            return room(tool: otherTool(), allowance: p.params.allowance).map { (p.params.depth.startDepth, p.params.depth.cutDepth, $0) }
        default: return nil
        }
    }

    /// Whether the profile's tabs land anywhere: automatic tabs need a closed vector among the selected ones, manual
    /// ones an anchor on a selected, existing, closed path (`TabAnchors.centers` ignores the others).
    public static func tabsWillBePlaced(_ op: ProfileOperation, in document: Document) -> Bool {
        let shapes = document.shapes(ids: op.setup.shapeIDs)
        guard let anchors = op.params.tabs.manualTabs else { return shapes.contains { $0.paths.contains(where: \.isClosed) } }
        let selected = Set(op.setup.shapeIDs)
        return anchors.contains { a in
            guard selected.contains(a.shapeID), let shape = document.shape(id: a.shapeID), shape.paths.indices.contains(a.pathIndex) else { return false }
            return shape.paths[a.pathIndex].isClosed
        }
    }

    /// What is wrong with a tool's own numbers: diameter, feed, plunge and spindle speed. Only the toolpath's
    /// primary tool can be fixed with the toolpath's override, so only its messages say so.
    public static func toolProblems(_ tool: Tool, profile: PostProfile, overridable: Bool) -> [String] {
        var out: [String] = []
        let fix = overridable ? "set it in the Tool Database or override it here" : "set it in the Tool Database"
        if !(tool.diameter > 0) { out.append("The tool's diameter is not above zero; set it in the Tool Database.") }
        if !(tool.feedRate > 0) { out.append("The feed rate is zero or less; \(fix).") }
        if !(tool.plungeRate > 0) { out.append("The plunge rate is zero or less; \(fix).") }
        if let rpm = rpmProblem(tool.spindleRPM, profile: profile) { out.append(rpm) }
        return out
    }

    /// Whether the operation's primary tool makes any cut: always, except a relief with finishing off whose
    /// roughing has another tool (or is off too), when the primary tool does nothing. (A roughing tool that is
    /// the primary tool itself, chosen or by default, is the primary tool cutting.)
    public static func primaryToolCuts(_ op: AnyOperation) -> Bool {
        guard case .relief3D(let o) = op else { return true }
        let roughsWithPrimary = o.params.roughing.toolID.map { $0 == op.setup.toolID } ?? true
        return o.params.finishing.isEnabled || (o.params.roughing.isEnabled && roughsWithPrimary)
    }

    /// The tools besides the primary one that the operation cuts with, in the order it uses them: a pocket's
    /// clearance tools, the flat-area clearance tools of a V-carve (only with a flat depth) and an inlay, and a
    /// relief's roughing tool when roughing is on and has one of its own. A relief's rest tool is not here: it
    /// only says what an earlier tool already finished, and cuts nothing. A pocket's clearance tools are the ones
    /// `PocketOperation.usableClearanceTools` keeps: larger than the finish tool and smaller than the clearance
    /// tool before; the rest are skipped by the generator. `primary` is the primary tool in document units.
    public static func secondaryToolIDs(of op: AnyOperation, primary: Tool, library: ToolLibrary, material: String?,
                                 units: LengthUnit) -> [UUID] {
        switch op {
        case .pocket(let o):
            let tol = CAMContext.defaultTolerance(units)
            var used: [UUID] = []
            var limit = Double.infinity
            for id in o.params.clearanceTools where id != op.setup.toolID {
                guard let t = library.tool(id: id)?.forMaterial(material).converted(to: units) else { continue }
                if t.diameter > primary.diameter + tol && t.diameter < limit - tol {
                    used.append(id)
                    limit = t.diameter
                }
            }
            return used
        case .vcarve(let o): return o.params.flatDepth == nil ? [] : o.params.clearanceTools.map(\.toolID)
        case .inlay(let o): return o.params.clearanceToolIDs
        case .relief3D(let o): return o.params.roughing.isEnabled ? o.params.roughing.toolID.map { [$0] } ?? [] : []
        default: return []
        }
    }

    /// Why `rpm` is outside what `profile`'s spindle runs, or nil. The range is the post's, not a constant.
    public static func rpmProblem(_ rpm: Double, profile: PostProfile) -> String? {
        // Below the floor S prints as S0, a stopped spindle, on every post (#99 item 10).
        if !(rpm >= PostProfile.minSpindleRPM) { return "The spindle speed must be at least 1 RPM." }
        guard !(rpm >= profile.minRPM && rpm <= profile.maxRPM) else { return nil }
        let range = "\(RulerTicks.label(profile.minRPM))–\(RulerTicks.label(profile.maxRPM)) RPM"
        return "The spindle speed \(RulerTicks.label(rpm)) RPM is outside the range \(range) of the post \(profile.name)."
    }

    /// The deepest the operation's own settings cut below the material top, for the kinds with a single cut depth.
    public static func cutDepth(of op: AnyOperation, tool: Tool) -> Double? {
        switch op {
        case .profile(let o): return o.params.depth.cutDepth
        case .pocket(let o): return o.params.depth.cutDepth
        case .fluting(let o): return o.params.depth.cutDepth
        case .engrave(let o): return o.params.depth.cutDepth
        case .facing(let o): return o.params.depth.cutDepth
        case .drill(let o): return o.params.cutDepth
        case .holeMill(let o): return o.params.cutDepth
        case .chamfer(let o): return (try? ChamferOperation.size(tool: tool, params: o.params))?.tipDepth
        default: return nil
        }
    }
}
