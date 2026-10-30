import CADCore
import CAMCore
import Foundation

public enum PostError: Error, Equatable, Sendable {
    case notImplemented(String)
    case noToolpaths
    case spindleSpeedOutOfRange(Double)
    /// A move in the named toolpath has a NaN or infinite coordinate, centre or feed.
    case nonFiniteMove(toolpath: String)
    /// The park-and-probe tool change cannot be written; the message says why.
    case probe(String)
    /// A dwell in the named toolpath is longer than `PostProfile.maxDwellSeconds`.
    case dwellTooLong(toolpath: String, seconds: Double)
    /// The post would write what its controller misreads (`PostProfile.dwellProblem`, `postProblem`, `placeholderProblem`); the
    /// message says why.
    case invalidPost(String)
}

/// Everything needed to write one G-code file.
public struct PostJob: Sendable {
    public var name: String
    /// Units of the toolpaths (the document's units).
    public var units: LengthUnit
    public var job: JobSetup
    /// Toolpaths in output order. A tool change is emitted whenever the tool changes.
    public var toolpaths: [Toolpath]
    public var materialDescription: String?
    /// Height above the material top (job units) to climb to after each tool change, and at
    /// the start, before the first XY move, when it is above safe Z: the tool then crosses
    /// keep-out zones and clamps taller than safe Z wherever the tool change left it. nil = safe Z.
    public var approachHeight: Double?

    public init(name: String, units: LengthUnit, job: JobSetup, toolpaths: [Toolpath],
                materialDescription: String? = nil, approachHeight: Double? = nil) {
        self.name = name; self.units = units; self.job = job; self.toolpaths = toolpaths
        self.materialDescription = materialDescription; self.approachHeight = approachHeight
    }
}

public protocol PostProcessor: Sendable {
    var profile: PostProfile { get }
    /// Full program text (header, tool changes, moves, footer), lines joined with "\n".
    func post(_ job: PostJob) throws -> String
}

/// The profile-driven post processor used for every shipped machine.
public struct TemplatePostProcessor: PostProcessor {
    public var profile: PostProfile

    public init(profile: PostProfile) { self.profile = profile }

    public func post(_ job: PostJob) throws -> String {
        try ProgramBuilder(profile: profile, job: job).build()
    }

    /// Combined export: toolpaths grouped by tool (first-appearance order) so each tool is
    /// loaded once, then posted as one program.
    public func postCombined(_ job: PostJob) throws -> String {
        var grouped = job
        grouped.toolpaths = ToolpathOrdering.groupedByTool(job.toolpaths)
        return try post(grouped)
    }

    /// Suggested file name for a program: "<job name>.<profile extension>".
    public func fileName(for jobName: String) -> String {
        let base = jobName.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : jobName
        return base + "." + profile.fileExtension
    }
}

public enum ToolpathOrdering {
    /// Combined export: reduces tool changes by letting a toolpath join an earlier group that
    /// uses the same tool, but only when the move is safe. A toolpath never moves ahead of:
    ///  * an earlier toolpath of its own operation (clearance before primary, flat before V);
    ///  * an earlier toolpath whose XY footprint (padded by both tool radii) overlaps its own
    ///    (rest machining, carving after pocketing, etc.);
    ///  * a toolpath followed by an operator pause, or any toolpath that would jump over one;
    /// and profile toolpaths never move at all (a through-cut or final profile stays where the
    /// user put it). Otherwise the user's order is kept.
    public static func groupedByTool(_ toolpaths: [Toolpath]) -> [Toolpath] {
        toolGroups(toolpaths).flatMap { $0 }
    }

    /// The runs of `groupedByTool`, in run order: each run uses one tool, and consecutive runs
    /// differ in tool. A tool can appear in several runs when merging would be unsafe.
    public static func toolGroups(_ toolpaths: [Toolpath]) -> [[Toolpath]] {
        var groups: [[Toolpath]] = []
        for tp in toolpaths {
            guard let g = groups.lastIndex(where: { $0.first?.tool.id == tp.tool.id }) else {
                groups.append([tp]); continue
            }
            let jumped = groups[(g + 1)...].flatMap { $0 }
            if jumped.isEmpty || canMove(tp, aheadOf: jumped) {
                groups[g].append(tp)
            } else {
                groups.append([tp])
            }
        }
        return groups
    }

    static func canMove(_ tp: Toolpath, aheadOf others: [Toolpath]) -> Bool {
        if tp.kind == .profile { return false }
        // An operator stop is a fixed point in the program: nothing before it may run after it
        // (the flipped part, the new clamp) and nothing after it may run before it.
        if tp.pauseAfter != nil || others.contains(where: { $0.pauseAfter != nil }) { return false }
        let r = tp.tool.diameter / 2
        let box = tp.xyBounds.insetBy(-r)
        for o in others {
            if let op = tp.operationID, op == o.operationID { return false }
            if box.isEmpty || o.xyBounds.isEmpty { continue }
            if box.intersects(o.xyBounds.insetBy(-o.tool.diameter / 2)) { return false }
        }
        return true
    }
}
