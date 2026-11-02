import CADCore
import CAMCore
import Foundation
import PostCore

/// A G-code file read back for previewing on the current job's stock (toolpaths-2d round 2).
/// Nothing is added to the document or exported; the tools are placeholders the user can edit.
struct GCodePreviewModel {
    struct ToolEntry: Identifiable, Equatable {
        var id: Int // segment index
        var label: String
        var tool: Tool
    }

    var fileName: String
    var units: LengthUnit
    var reader: GCodeReader.Result
    var tools: [ToolEntry]

    init(text: String, fileName: String, units: LengthUnit, job: JobSetup) {
        self.fileName = fileName
        self.units = units
        let coords = MachineCoordinates(job: job)
        reader = GCodeReader.read(text, units: units, assumedUnits: units, startZ: coords.safeZ)
        let header = GCodeReader.headerTools(text, units: units)
        let rows = GCodeReader.headerToolList(text, units: units)
        tools = reader.segments.enumerated().map { i, seg in
            // A stop tool change has no T word: its tool is the one header row with its name (#126).
            let byName = seg.toolNumber == nil ? seg.toolComment.flatMap { c in
                let matches = rows.filter { $0.tool.name == c }
                return matches.count == 1 ? matches[0] : nil
            } : nil
            let n = seg.toolNumber ?? byName?.number
            var t = Tool(name: "Tool", kind: .endMill, units: units, number: n ?? 0,
                         diameter: units == .inch ? 0.25 : 6, stepdown: 0, stepover: 0,
                         spindleRPM: seg.spindleRPM, feedRate: 0, plungeRate: 0)
            if let h = byName?.tool ?? n.flatMap({ header[$0] }) {
                t.name = h.name; t.kind = h.kind; t.diameter = h.diameter
                if h.kind == .vBit || h.kind == .engraving { t.angle = 60 }
            } else if let c = seg.toolComment, !c.isEmpty {
                t.name = c
            }
            let head = n.map { "T\($0)" } ?? (seg.startsAtToolChange ? "Tool change" : "No tool change")
            let label = head + (t.name == "Tool" ? "" : " – \(t.name)")
            return ToolEntry(id: i, label: label, tool: t)
        }
    }

    /// One preview toolpath per tool segment, with the (possibly edited) placeholder tools.
    var toolpaths: [Toolpath] {
        zip(reader.segments, tools).map { seg, entry in
            Toolpath(name: entry.label, kind: .profile, tool: entry.tool, spindleRPM: seg.spindleRPM, moves: seg.moves)
        }
    }

    var summary: String {
        let u = reader.programUnits.map { $0 == .inch ? "inches (G20)" : "millimeters (G21)" } ?? "units not stated"
        return "\(reader.moveCount) moves, \(tools.count) tool\(tools.count == 1 ? "" : "s"), \(u)"
    }
}
