import CADCore
import CAMCore
import Foundation
import PostCore

/// Per-toolpath times and the tool-change sequence of a combined export (sidebar summary and
/// the "Save All Toolpaths" sheet). Pure: built from operations and their results.
struct JobSummary: Equatable {
    struct Row: Equatable, Identifiable {
        var id: UUID
        var name: String
        var kind: OperationKind
        /// "T1 · 1/4" End Mill" for each distinct tool the operation's toolpaths use, in order.
        var tools: [String]
        /// nil until calculated (or when the calculation failed).
        var estimatedSeconds: TimeInterval?
        var isEnabled: Bool
        var error: String?
    }

    /// One tool load in the combined program.
    struct ToolLoad: Equatable {
        var number: Int
        var name: String
        var toolpathNames: [String]
    }

    /// An operator pause between two toolpaths.
    struct PauseRow: Equatable {
        var after: String
        var text: String
    }

    var rows: [Row]
    /// Tool loads (each is a manual tool change at the machine) in program order.
    var sequence: [ToolLoad]
    /// Operator pauses in program order (the last toolpath's pause is never written).
    var pauses: [PauseRow] = []
    /// Stops at the machine: tool changes plus pauses, a pause that ends in a tool change counted once.
    var stops: Int = 0
    /// Cutting, rapids and dwell of the enabled toolpaths in program order, including the rapids
    /// that carry the tool from the end of one toolpath to the start of the next (the motion the
    /// 3D preview times). No tool-change allowance, not even for a change inside one operation:
    /// those are all in `toolChangeAllowance`.
    var machiningSeconds: TimeInterval
    /// Allowance for one manual tool change (the user's time-estimate setting).
    var toolChangeSeconds: TimeInterval = 0

    /// False until at least one enabled toolpath has been calculated; a total of 0s then means
    /// "not calculated", not "instant".
    var hasEstimate: Bool { rows.contains { $0.isEnabled && $0.estimatedSeconds != nil } }

    /// Changes after the first tool is loaded.
    var toolChanges: Int { max(0, sequence.count - 1) }
    /// What the stops add: the same allowance the 3D preview counts, so the sidebar and the
    /// preview agree instead of showing two different times for one job.
    var toolChangeAllowance: TimeInterval { Double(stops) * toolChangeSeconds }
    var totalSeconds: TimeInterval { machiningSeconds + toolChangeAllowance }

    static func label(_ tool: Tool) -> String { "T\(tool.number) · \(tool.name)" }

    /// The motion is `settings`' estimate of the toolpaths in program order (`rapidRate` in `units`
    /// per minute), so it sees the rapids between toolpaths that a per-operation estimate cannot;
    /// the allowance (`settings.toolChangeSeconds`) is added per stop in `totalSeconds`.
    static func make(operations: [AnyOperation], results: [UUID: ToolpathResult], groupByTool: Bool,
                     settings: TimeEstimateSettings, rapidRate: Double, units: LengthUnit) -> JobSummary {
        let rows = operations.map { op -> Row in
            let r = results[op.id]
            var tools: [String] = []
            for tp in r?.toolpaths ?? [] where !tools.contains(label(tp.tool)) { tools.append(label(tp.tool)) }
            let ok = r.map { $0.error == nil } ?? false
            return Row(id: op.id, name: op.setup.name, kind: op.kind, tools: tools,
                       estimatedSeconds: ok ? r?.estimatedSeconds : nil, isEnabled: op.setup.isEnabled,
                       error: r?.error)
        }
        let tps = ProgramPauses.effective(GCodeExporter.toolpaths(scope: .all, operations: operations, results: results,
                                                                  groupByTool: groupByTool))
        // A row's own time includes the tool changes inside its operation (a pocket's clearance
        // tool, a V-carve's flat-area tool); the job total counts every stop once, below. The
        // motion is timed over the toolpaths in program order, so the rapids between them count.
        let total = settings.estimate(tps, rapidRate: rapidRate, units: units, toolChanges: false)
        var pauses: [PauseRow] = []
        var stops = 0
        for (i, tp) in tps.enumerated() where i > 0 {
            if ToolpathStats.stopsBefore(tp, after: tps[i - 1]) { stops += 1 }
            if let p = tps[i - 1].pauseAfter { pauses.append(PauseRow(after: tps[i - 1].name, text: p.text(afterToolpath: tps[i - 1].name))) }
        }
        return JobSummary(rows: rows, sequence: sequence(of: tps), pauses: pauses, stops: stops,
                          machiningSeconds: total, toolChangeSeconds: settings.toolChangeSeconds)
    }

    /// What a summary is made from, so one can be reused while none of it has changed. Results are
    /// replaced whole (a recalculation makes new toolpath objects; a settings change rewrites the
    /// estimates), so a result is known by its toolpath ids, estimate and error; an operator pause
    /// lives on the operation, which the key holds in full.
    struct Key: Hashable {
        struct Result: Hashable {
            var id: UUID
            var toolpathIDs: [UUID]
            /// A tool renamed in the database is renamed in place in its toolpaths.
            var toolNames: [String]
            var estimatedSeconds: TimeInterval
            var error: String?
        }
        var operations: [AnyOperation]
        var results: [Result]
        var groupByTool: Bool
        var settings: TimeEstimateSettings
        var rapidRate: Double
        var units: LengthUnit

        init(operations: [AnyOperation], results: [UUID: ToolpathResult], groupByTool: Bool, settings: TimeEstimateSettings,
             rapidRate: Double, units: LengthUnit) {
            self.operations = operations
            self.results = results.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, r in
                Result(id: id, toolpathIDs: r.toolpaths.map(\.id), toolNames: r.toolpaths.map(\.tool.name), estimatedSeconds: r.estimatedSeconds, error: r.error)
            }
            self.groupByTool = groupByTool; self.settings = settings; self.rapidRate = rapidRate; self.units = units
        }
    }

    /// The last summary and the key it was made from. Timing the program is a motion solve over
    /// every move, and the sidebar redraws with every document change, so a summary is rebuilt only
    /// when its key changes; keys are compared whole, not by hash.
    final class Memo {
        private var last: (key: Key, summary: JobSummary)?
        /// How many summaries were built (what the tests count).
        private(set) var builds = 0

        func summary(operations: [AnyOperation], results: [UUID: ToolpathResult], groupByTool: Bool,
                     settings: TimeEstimateSettings, rapidRate: Double, units: LengthUnit) -> JobSummary {
            let key = Key(operations: operations, results: results, groupByTool: groupByTool, settings: settings,
                          rapidRate: rapidRate, units: units)
            if let last, last.key == key { return last.summary }
            let s = JobSummary.make(operations: operations, results: results, groupByTool: groupByTool,
                                    settings: settings, rapidRate: rapidRate, units: units)
            last = (key, s)
            builds += 1
            return s
        }
    }

    /// Consecutive toolpaths sharing a tool form one load.
    static func sequence(of toolpaths: [Toolpath]) -> [ToolLoad] {
        var out: [(id: UUID, load: ToolLoad)] = []
        for tp in toolpaths {
            if let last = out.last, last.id == tp.tool.id {
                out[out.count - 1].load.toolpathNames.append(tp.name)
            } else {
                out.append((tp.tool.id, ToolLoad(number: tp.tool.number, name: tp.tool.name, toolpathNames: [tp.name])))
            }
        }
        return out.map(\.load)
    }
}
