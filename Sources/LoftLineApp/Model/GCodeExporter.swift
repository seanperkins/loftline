import CADCore
import CAMCore
import Foundation
import PostCore

/// What to write into one G-code file.
enum GCodeExportScope: Hashable {
    /// All enabled, calculated toolpaths.
    case all
    /// A single operation's toolpaths.
    case operation(UUID)
}

struct GCodeExportResult {
    var text: String?
    var issues: [GCodeIssue]
    var errorMessage: String?
    var toolpathCount: Int
    /// Where the program cuts deepest, read back from `text`; nil without text or cuts.
    var deepestCut: DeepestCut? = nil

    var hasErrors: Bool { issues.contains { $0.severity == .error } }
}

/// Collects toolpaths, runs the post processor and the validator. Pure (no UI).
enum GCodeExporter {
    /// UserDefaults key for the shared "group by tool" choice. The export, validation and
    /// tool-change summary panels and the 3D preview all read it, so the simulated order is
    /// always the exported order. Off by default: the user's toolpath order is kept.
    static let groupByToolKey = "loftline.groupByTool"
    static func toolpaths(scope: GCodeExportScope, operations: [AnyOperation],
                          results: [UUID: ToolpathResult], groupByTool: Bool) -> [Toolpath] {
        switch scope {
        case .operation(let id):
            guard let op = operations.first(where: { $0.id == id }) else { return results[id]?.toolpaths ?? [] }
            return operationToolpaths(op, results: results)
        case .all:
            let tps = operations.filter(\.setup.isEnabled).flatMap { withPause($0.setup.pauseAfter, operationToolpaths($0, results: results)) }
            return groupByTool ? ToolpathOrdering.groupedByTool(tps) : tps
        }
    }

    /// One operation's calculated toolpaths with its post-time settings that belong on every toolpath (coolant).
    /// Every export path collects an operation's toolpaths through here; the pause is added only for whole programs.
    static func operationToolpaths(_ op: AnyOperation, results: [UUID: ToolpathResult]) -> [Toolpath] {
        withCoolant(op.setup.coolant, results[op.id]?.toolpaths ?? [])
    }

    /// `toolpaths` with `coolant` on every one (unlike a pause, which belongs only after the last).
    static func withCoolant(_ coolant: Coolant?, _ toolpaths: [Toolpath]) -> [Toolpath] {
        toolpaths.map { var t = $0; t.coolant = coolant; return t }
    }

    /// `toolpaths` (one operation's) with the operation's operator pause on the last one that cuts.
    /// Single-operation exports skip this: that file is a program on its own.
    static func withPause(_ pause: PauseStep?, _ toolpaths: [Toolpath]) -> [Toolpath] {
        guard let pause, let last = toolpaths.lastIndex(where: { !$0.moves.isEmpty }) else { return toolpaths }
        var out = toolpaths
        out[last].pauseAfter = pause
        return out
    }

    /// Errors for enabled operations that have no toolpaths to export (the calculation failed
    /// or never ran): a program with a step missing must not be saved without the explicit
    /// "Save Anyway" confirmation.
    static func missingOperationIssues(_ operations: [AnyOperation], results: [UUID: ToolpathResult]) -> [GCodeIssue] {
        operations.filter(\.setup.isEnabled).compactMap { op in
            guard let r = results[op.id] else {
                return GCodeIssue(severity: .error, message: "\(op.setup.name) is missing from the program: not calculated")
            }
            guard let e = r.error else { return nil }
            return GCodeIssue(severity: .error, message: "\(op.setup.name) is missing from the program: \(e)")
        }
    }

    /// Errors for toolpaths that come over a keep-out zone below its top (+ clearance margin).
    static func keepOutIssues(_ toolpaths: [Toolpath], document doc: Document) -> [GCodeIssue] {
        guard let zones = doc.keepOutZones, !zones.isEmpty else { return [] }
        let margin = doc.units == .inch ? 0.05 : 1.0
        let tol = doc.units == .inch ? 0.0005 : 0.01
        return KeepOut.violations(toolpaths, zones: zones, coords: MachineCoordinates(job: doc.job), margin: margin,
                                  tolerance: tol).map { v in
            let what = v.isRapid ? "rapids over" : "cuts into"
            return GCodeIssue(severity: .error, message: "\(v.toolpathName) \(what) keep-out zone \"\(v.zoneName)\" near X\(RulerTicks.label((v.at.x * 1000).rounded() / 1000)) Y\(RulerTicks.label((v.at.y * 1000).rounded() / 1000))")
        }
    }

    /// Raises the post's travel between toolpaths over "lift over" keep-out zones.
    static func linkOverKeepOutZones(_ toolpaths: [Toolpath], document doc: Document) -> [Toolpath] {
        guard let zones = doc.keepOutZones, zones.contains(where: { $0.liftOver == true }) else { return toolpaths }
        let margin = doc.units == .inch ? 0.05 : 1.0
        let tol = doc.units == .inch ? 0.0005 : 0.01
        return KeepOutAvoidance.link(toolpaths, zones: zones, coords: MachineCoordinates(job: doc.job), margin: margin,
                                     tolerance: tol)
    }

    /// Name of the modelled end-of-program travel in keep-out messages.
    static let homeMoveName = "Move home (end of program)"

    /// The footer's travel after the last toolpath, machine frame, document units: the post
    /// retracts to safe Z, then the built-in footers go to Home Z and across to home XY. Only
    /// the moves the profile's footer actually makes ({HOME_Z}, {HOME_X}/{HOME_Y}) are included,
    /// Z first. Empty when the footer does not go home.
    static func homeTravel(from end: Vec3, document doc: Document, profile: PostProfile) -> [Vec3] {
        let footer = profile.footer.joined(separator: "\n")
        let goesZ = footer.contains("{HOME_Z}")
        let goesXY = footer.contains("{HOME_X}") || footer.contains("{HOME_Y}")
        guard goesZ || goesXY else { return [] }
        let coords = MachineCoordinates(job: doc.job)
        var pts = [Vec3(end.xy, z: max(end.z, coords.safeZ))]
        var z = pts[0].z
        if goesZ { z = coords.homeZ; pts.append(Vec3(end.xy, z: z)) }
        if goesXY { pts.append(Vec3(doc.job.home, z: z)) }
        return pts
    }

    /// The footer's travel home as a rapid-only toolpath with the last toolpath's tool, so the
    /// keep-out checks see it as the next move of the program; nil when there is none.
    static func homeMove(after toolpaths: [Toolpath], document doc: Document, profile: PostProfile) -> Toolpath? {
        guard let last = toolpaths.last(where: { $0.moves.contains { $0.target != nil } }),
              let end = last.moves.last(where: { $0.target != nil })?.target else { return nil }
        let pts = homeTravel(from: end, document: doc, profile: profile)
        guard !pts.isEmpty else { return nil }
        var tp = last
        tp.name = homeMoveName
        tp.moves = pts.map { .rapid(to: $0) }
        tp.metadata = [:]
        return tp
    }

    /// Raises the footer's move home over "lift over" keep-out zones taller than Home Z.
    static func linkHomeOverKeepOutZones(_ toolpaths: [Toolpath], document doc: Document,
                                         profile: PostProfile) -> [Toolpath] {
        guard let zones = doc.keepOutZones, zones.contains(where: { $0.liftOver == true }),
              let home = homeMove(after: toolpaths, document: doc, profile: profile) else { return toolpaths }
        let margin = doc.units == .inch ? 0.05 : 1.0
        let tol = doc.units == .inch ? 0.0005 : 0.01
        return KeepOutAvoidance.linkTravel(after: toolpaths, through: home.moves.compactMap(\.target), zones: zones,
                                           coords: MachineCoordinates(job: doc.job), margin: margin, tolerance: tol)
    }

    /// Height above the material top for the first XY move after each tool change: above the
    /// tallest keep-out zone or clamp (+ 2 × the check's clearance) when that is above safe Z,
    /// since where the tool change leaves the spindle is unknown. nil = safe Z is enough.
    static func approachHeight(document doc: Document) -> Double? {
        let margin = doc.units == .inch ? 0.05 : 1.0
        let tops = (doc.keepOutZones ?? []).filter { $0.outline.count > 2 }.map(\.height)
            + Fixtures.zones(in: doc).map(\.height)
        guard let h = tops.max() else { return nil }
        let clear = h + 2 * margin
        return clear > doc.job.safeZ + 1e-9 ? clear : nil
    }

    static func materialDescription(_ doc: Document) -> String {
        let j = doc.job
        func f(_ v: Double) -> String { RulerTicks.label(v) }
        return "\(f(j.width)) x \(f(j.height)) x \(f(j.thickness)) \(doc.units.abbreviation)"
    }

    /// `sheetToolpaths`: with a probing post, every toolpath of the posted sheet (`sheetToolpathsIfProbing`), which the
    /// touch-off spot is checked against; nil with a probing post refuses, so a caller that forgets it fails closed.
    static func export(project: LoftLineProject, toolpaths: [Toolpath], profile: PostProfile,
                       jobName: String, sheetToolpaths: SheetToolpaths? = nil) -> GCodeExportResult {
        let doc = project.document
        guard !toolpaths.isEmpty else {
            return GCodeExportResult(text: nil, issues: [], errorMessage: "There are no calculated toolpaths to export.",
                                     toolpathCount: 0)
        }
        if let problem = spotProblem(project: project, exported: toolpaths, sheet: sheetToolpaths, profile: profile) {
            return refused(problem, toolpathCount: toolpaths.count)
        }
        // Travel between toolpaths crosses lift-over zones at safe Z unless raised here: each
        // operation was re-routed on its own, so only the final order shows these moves.
        // The footer's move home is a fixed path too: lifted the same way, then checked.
        let toolpaths = linkHomeOverKeepOutZones(linkOverKeepOutZones(toolpaths, document: doc), document: doc,
                                                 profile: profile)
        let checked = toolpaths + [homeMove(after: toolpaths, document: doc, profile: profile)].compactMap { $0 }
        let validator = GCodeValidator(profile: profile, job: doc.job, units: doc.units)
        var issues = validator.validate(toolpaths: toolpaths)
        issues += keepOutIssues(checked, document: doc)
        issues += LayoutChecks.toolpaths(toolpaths, job: doc.job, units: doc.units)
        issues += PreflightChecks.issues(project: project, toolpaths: toolpaths, units: doc.units)
        issues += [ToolChangeZ.warning(toolpaths: toolpaths, profile: profile)].compactMap { $0 }
        issues += LayoutChecks.keepOut(checked, zones: Fixtures.zones(in: doc), job: doc.job, units: doc.units).map { i in
            guard i.message.contains(homeMoveName) else { return i }
            var fixed = i
            fixed.message = i.message.replacingOccurrences(of: "raise safe Z", with: "raise Home Z")
            return fixed
        }
        // The post header already prints W x H x T, so no extra material description.
        let job = PostJob(name: jobName, units: doc.units, job: doc.job, toolpaths: toolpaths,
                          approachHeight: approachHeight(document: doc))
        do {
            let text = try TemplatePostProcessor(profile: profile).post(job)
            issues += validator.validate(gcode: text)
            return GCodeExportResult(text: text, issues: GCodeIssue.merged(issues), errorMessage: nil, toolpathCount: toolpaths.count,
                                     deepestCut: DeepestCut.find(in: text, job: doc.job, units: doc.units))
        } catch PostError.notImplemented(let what) {
            return GCodeExportResult(text: nil, issues: issues,
                                     errorMessage: "\(what) is not available in this build yet.",
                                     toolpathCount: toolpaths.count)
        } catch PostError.probe(let message) {
            return GCodeExporter.refused(message, issues: issues, toolpathCount: toolpaths.count)
        } catch PostError.spindleSpeedOutOfRange(let rpm) {
            return GCodeExportResult(text: nil, issues: issues,
                                     errorMessage: String(format: "Spindle speed %.0f RPM is outside the machine's range (%.0f–%.0f).",
                                                          rpm, profile.minRPM, profile.maxRPM),
                                     toolpathCount: toolpaths.count)
        } catch {
            return GCodeExportResult(text: nil, issues: issues, errorMessage: "\(error)", toolpathCount: toolpaths.count)
        }
    }

    /// No program: a condition under which no valid program can be written (there is no Save Anyway for it).
    static func refused(_ message: String, issues: [GCodeIssue] = [], toolpathCount: Int) -> GCodeExportResult {
        GCodeExportResult(text: nil, issues: issues, errorMessage: message, toolpathCount: toolpathCount)
    }

    private static let fileNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))

    /// File name like "Sign_Profile_1.tap": unsafe characters replaced, and a leading dot too, so the
    /// file is never hidden from the operator.
    static func suggestedFileName(jobName: String, operationName: String?, profile: PostProfile) -> String {
        var base = jobName.isEmpty ? "Untitled" : jobName
        if let op = operationName { base += "_" + op }
        var clean = String(base.unicodeScalars.map { fileNameCharacters.contains($0) ? Character($0) : "_" })
        if clean.hasPrefix(".") { clean = "_" + clean.dropFirst() }
        return clean + "." + fileExtension(for: profile)
    }

    /// The post profile's extension, cleaned: a profile is any JSON file a user dropped in.
    static func fileExtension(for profile: PostProfile) -> String {
        let ext = String(profile.fileExtension.unicodeScalars.filter { fileNameCharacters.contains($0) && $0 != "." })
        return ext.isEmpty ? "tap" : ext
    }
}
