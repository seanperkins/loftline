import CADCore
import CAMCore
import Foundation

/// Renders one `PostJob` with a `PostProfile`:
/// header comments → units + preamble → per tool: tool change, safe Z, spindle + dwell, moves
/// → footer. Toolpaths are converted to the profile's units first.
struct ProgramBuilder {
    let profile: PostProfile
    let job: PostJob

    /// Job setup and toolpaths in OUTPUT units.
    private let setup: JobSetup
    private let toolpaths: [Toolpath]
    private let coords: MachineCoordinates
    /// Machine Z for the first XY move after a tool change (never below safe Z).
    private let approachZ: Double

    init(profile: PostProfile, job: PostJob) {
        self.profile = profile
        self.job = job
        let f = job.units.factor(to: profile.units)
        setup = job.job.scaled(by: f)
        toolpaths = job.toolpaths.map { $0.scaled(from: job.units, to: profile.units) }
        coords = MachineCoordinates(job: setup)
        let c = coords
        approachZ = max(c.safeZ, job.approachHeight.map { c.z(aboveTop: $0 * f) } ?? c.safeZ)
    }

    func build() throws -> String {
        let active = toolpaths.filter { !$0.moves.isEmpty }
        guard !active.isEmpty else { throw PostError.noToolpaths }
        for tp in active where tp.spindleRPM < profile.minRPM || tp.spindleRPM > profile.maxRPM {
            throw PostError.spindleSpeedOutOfRange(tp.spindleRPM)
        }
        // "Xnan" is not a word any controller rejects reliably; NaN also hides from every
        // comparison in the validators, so refuse it here.
        for tp in active where !tp.moves.allSatisfy(Self.isFinite) {
            throw PostError.nonFiniteMove(toolpath: tp.name)
        }

        var w = GCodeWriter(profile: profile, safeZ: coords.safeZ)
        if profile.headerComments { writeHeader(into: &w, toolpaths: active) }
        w.code(profile.unitsCode)
        for line in render(profile.preamble) { w.code(line) }
        // Absolute arc centres are never a controller's default: state the mode unless the preamble does.
        if profile.arcOutput == .absoluteIJ, !profile.preamble.contains(where: { $0.contains("G90.1") }) {
            w.code("G90.1")
        }

        var currentTool: UUID?
        var currentRPM: Double?
        var coolantOn: Coolant?
        for (index, tp) in active.enumerated() {
            if tp.tool.id != currentTool {
                if currentTool != nil { w.retract(to: coords.safeZ) }
                coolantOff(&coolantOn, into: &w)
                writeToolChange(tp, into: &w)
                currentTool = tp.tool.id
                currentRPM = nil
            }
            if tp.spindleRPM != currentRPM {
                writeSpindleStart(tp, into: &w)
                currentRPM = tp.spindleRPM
            }
            if tp.coolant != coolantOn {
                // Mist to Air turns the one off first: never both on.
                coolantOff(&coolantOn, into: &w)
                if let c = tp.coolant { w.code(c.code); coolantOn = c }
            }
            w.comment("Toolpath: \(tp.name) [\(tp.kind.displayName)]")
            writeMoves(tp.moves, into: &w)
            // A stop belongs between toolpaths: the program's own end already stops the machine.
            if let pause = tp.pauseAfter, index + 1 < active.count {
                let next = active[index + 1]
                coolantOff(&coolantOn, into: &w)
                writePause(pause, after: tp, into: &w)
                currentRPM = nil   // the pause stops the spindle
                // A tool change that follows re-enters the work itself.
                if next.tool.id == tp.tool.id { reenter(before: next, into: &w) }
            }
        }

        w.retract(to: coords.safeZ)
        coolantOff(&coolantOn, into: &w)
        for line in render(profile.footer) { w.code(line) }
        return w.lines.joined(separator: "\n") + "\n"
    }

    // MARK: Sections

    static func isFinite(_ move: Move) -> Bool {
        switch move {
        case .rapid(let p): return p.isFinite
        case .linear(let p, let f): return p.isFinite && f.isFinite
        case .arcCW(let p, let c, let f), .arcCCW(let p, let c, let f): return p.isFinite && c.isFinite && f.isFinite
        case .dwell(let s): return s.isFinite
        }
    }

    private func fmt(_ v: Double) -> String { NumberFormat.fixed(v, decimals: profile.decimals) }

    private func baseValues() -> [String: String] {
        [
            "SAFE_Z": fmt(coords.safeZ),
            "HOME_X": fmt(setup.home.x),
            "HOME_Y": fmt(setup.home.y),
            "HOME_Z": fmt(coords.homeZ),
            "JOB_NAME": TemplateRenderer.commentSafe(job.name),
            "POST_NAME": TemplateRenderer.commentSafe(profile.name),
            "POST_VERSION": profile.version,
            "SECONDS": NumberFormat.compact(profile.spindleDwellSeconds),
        ]
    }

    private func render(_ lines: [String], tool: Toolpath? = nil) -> [String] {
        var values = baseValues()
        if let tp = tool {
            values["T"] = String(tp.tool.number)
            values["TOOL_NAME"] = TemplateRenderer.commentSafe(tp.tool.name)
            values["S"] = NumberFormat.fixed(tp.spindleRPM, decimals: 0)
        }
        return TemplateRenderer(values: values).render(lines)
    }

    private func writeHeader(into w: inout GCodeWriter, toolpaths: [Toolpath]) {
        let u = profile.units.abbreviation
        w.comment("Job: \(job.name)")
        w.comment("Post: \(profile.name) v\(profile.version)")
        w.comment("Units: \(profile.units == .inch ? "inches" : "millimetres")")
        var material = "Material: \(fmt(setup.width)) x \(fmt(setup.height)) x \(fmt(setup.thickness)) \(u)"
        if let d = job.materialDescription, !d.isEmpty { material += " - \(d)" }
        w.comment(material)
        switch setup.zZero {
        case .materialTop: w.comment("Z zero: material top [bottom at Z\(fmt(coords.materialBottomZ))]")
        case .spoilboard: w.comment("Z zero: spoilboard surface [top at Z\(fmt(coords.materialTopZ))]")
        }
        w.comment("XY origin: \(Self.originName(setup.xyOrigin))")
        if let o = setup.datumOffset, o != .zero { w.comment("XY datum offset: X\(fmt(o.x)) Y\(fmt(o.y))") }
        w.comment("Safe Z: \(fmt(coords.safeZ))  Home: X\(fmt(setup.home.x)) Y\(fmt(setup.home.y)) Z\(fmt(coords.homeZ))")
        w.comment("Tools:")
        var seen = Set<UUID>()
        for tp in toolpaths where seen.insert(tp.tool.id).inserted {
            let t = tp.tool
            w.comment("  T\(t.number): \(t.name) - \(t.kind.displayName), dia \(fmt(t.diameter)) \(u)")
        }
        w.comment("Toolpaths:")
        for tp in toolpaths {
            w.comment("  \(tp.name) [\(tp.kind.displayName), T\(tp.tool.number), S\(NumberFormat.fixed(tp.spindleRPM, decimals: 0))]")
        }
        // The last toolpath is skipped: the program's own end stops the machine (see `build`).
        let stops = toolpaths.dropLast().compactMap { tp in tp.pauseAfter.map { (tp, $0) } }
        if !stops.isEmpty {
            w.comment("Pauses - the machine waits for Cycle Start:")
            for (tp, pause) in stops {
                w.comment("  after \(tp.name): \(pause.text(afterToolpath: tp.name)) [\(pause.stopCode)]")
            }
        }
        let seconds = PostTimeEstimator.estimate(toolpaths, rapidRate: profile.rapidRate,
                                                 spindleDwell: profile.spindleDwellSeconds)
        w.comment("Estimated time: \(NumberFormat.duration(seconds))")
    }

    private func writeToolChange(_ tp: Toolpath, into w: inout GCodeWriter) {
        for line in render(profile.toolChange, tool: tp) { w.code(line) }
        if profile.useToolLengthOffset {
            w.code(render([profile.toolLengthOffset], tool: tp)[0])
        }
        reenter(before: tp, into: &w)
    }

    /// Retract, stop the spindle, show the message and wait for the operator (M0, or M1 for an optional stop).
    private func writePause(_ pause: PauseStep, after tp: Toolpath, into w: inout GCodeWriter) {
        w.retract(to: coords.safeZ)
        w.comment("Pause after toolpath: \(tp.name)")
        var values = baseValues()
        values["MESSAGE"] = TemplateRenderer.commentSafe(pause.text(afterToolpath: tp.name))
        values["STOP"] = pause.stopCode
        for line in TemplateRenderer(values: values).render(profile.pauseLines) { w.code(line) }
    }

    /// After a tool change or a stop the controller may have moved (a tool-change macro, the operator
    /// jogging): restate everything, climb to the approach height and cross to the next toolpath at
    /// that height, so the traverse still clears clamps and keep-out zones taller than safe Z.
    private func reenter(before next: Toolpath, into w: inout GCodeWriter) {
        w.resetModalState()
        w.forceRapidZ(approachZ)
        if approachZ > coords.safeZ + 1e-9, let first = next.moves.first(where: { $0.target != nil })?.target {
            w.rapid(to: Vec3(first.xy, z: approachZ))
        }
    }

    /// `M9` when coolant is on; a pause or a tool change turns it off, and the next toolpath turns its own on.
    private func coolantOff(_ on: inout Coolant?, into w: inout GCodeWriter) {
        guard on != nil else { return }
        w.code("M9")
        on = nil
    }

    private func writeSpindleStart(_ tp: Toolpath, into w: inout GCodeWriter) {
        w.code(render([profile.spindleOn], tool: tp)[0])
        w.dwell(seconds: profile.spindleDwellSeconds)
    }

    private func writeMoves(_ moves: [Move], into w: inout GCodeWriter) {
        for move in moves {
            switch move {
            case .rapid(let p): w.rapid(to: p)
            case .linear(let p, let f): w.linear(to: p, feed: f)
            case .arcCW(let p, let c, let f): w.arc(to: p, center: c, clockwise: true, feed: f)
            case .arcCCW(let p, let c, let f): w.arc(to: p, center: c, clockwise: false, feed: f)
            case .dwell(let s): w.dwell(seconds: s)
            }
        }
    }

    static func originName(_ o: XYOrigin) -> String {
        switch o {
        case .lowerLeft: return "lower left"
        case .lowerRight: return "lower right"
        case .upperLeft: return "upper left"
        case .upperRight: return "upper right"
        case .center: return "centre"
        }
    }
}
