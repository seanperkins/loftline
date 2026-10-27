import CADCore
import CAMCore
import Foundation
import PostCore

/// A project carries a copy of every tool its operations use, and posts with that copy: the same file cuts the same on
/// any Mac, whatever its tool library holds. The library supplies only the tools a project does not carry.
enum ToolSync {
    /// The project carries exactly the tools its operations reference, in operation order. A carried tool is kept as it
    /// is, never replaced from the library; a referenced tool it lacks is added from the library (a tool nobody has is
    /// skipped); a tool no operation references is dropped.
    static func carrying(_ p: LoftLineProject, library: ToolLibrary) -> LoftLineProject {
        var carried: [UUID: Tool] = [:]
        for t in p.tools where carried[t.id] == nil { carried[t.id] = t }
        var seen = Set<UUID>()
        var tools: [Tool] = []
        for op in p.operations {
            for id in op.referencedToolIDs where seen.insert(id).inserted {
                if let t = carried[id] ?? library.tool(id: id) { tools.append(t) }
            }
        }
        var q = p
        q.tools = tools
        return q
    }

    /// A Tool Database edit reaching a project: a carried tool whose library entry changed in this update is replaced by
    /// the new library entry, but only when the carried copy equalled the old library entry. A copy that had already
    /// diverged is left alone (it keeps its warning), so a rename of a library tool cannot swap a diameter. The carried
    /// tool's own `notes` and `group` are kept.
    static func applyingLibraryChange(old: ToolLibrary, new: ToolLibrary, to p: LoftLineProject) -> LoftLineProject {
        var q = p
        for i in q.tools.indices {
            let id = q.tools[i].id
            guard let was = old.tool(id: id), let now = new.tool(id: id), was != now,
                  q.tools[i].samePostingFields(as: was) else { continue }
            var next = now
            next.notes = q.tools[i].notes
            next.group = q.tools[i].group
            q.tools[i] = next
        }
        return q
    }

    /// The carried tools that differ from the library's tool of the same id (nothing for a tool the library lacks).
    static func differences(_ p: LoftLineProject, library: ToolLibrary) -> [(carried: Tool, library: Tool)] {
        p.tools.compactMap { carried in
            guard let lib = library.tool(id: carried.id), !carried.samePostingFields(as: lib) else { return nil }
            return (carried, lib)
        }
    }

    /// One warning per differing tool.
    static func issues(for p: LoftLineProject, library: ToolLibrary) -> [GCodeIssue] {
        differences(p, library: library).map { d in
            GCodeIssue(severity: .warning, message:
                "Tool \"\(d.carried.name)\" in this project differs from the library's (\(describe(d.carried, d.library))). "
                + "Job Setup > Update This Project uses the library's.")
        }
    }

    /// Update This Project: every carried tool that has a library counterpart is replaced by it, whole; the rest stay.
    static func updated(_ p: LoftLineProject, library: ToolLibrary) -> LoftLineProject {
        var q = p
        for i in q.tools.indices {
            if let lib = library.tool(id: q.tools[i].id) { q.tools[i] = lib }
        }
        return q
    }

    /// "diameter 0.25 in, library 0.375 in; feed rate 40, library 60": the first few fields that differ.
    private static func describe(_ c: Tool, _ l: Tool) -> String {
        func length(_ v: Double, _ t: Tool) -> String { "\(RulerTicks.label(v)) \(t.units.abbreviation)" }
        func number(_ v: Double) -> String { RulerTicks.label(v) }
        var parts: [String] = []
        if c.name != l.name { parts.append("name \"\(c.name)\", library \"\(l.name)\"") }
        if c.number != l.number { parts.append("T\(c.number), library T\(l.number)") }
        if c.kind != l.kind { parts.append("tool type") }
        if c.diameter != l.diameter || c.units != l.units { parts.append("diameter \(length(c.diameter, c)), library \(length(l.diameter, l))") }
        if c.flutes != l.flutes { parts.append("flutes \(c.flutes), library \(l.flutes)") }
        if c.angle != l.angle { parts.append("angle") }
        if c.tipDiameter != l.tipDiameter { parts.append("tip diameter \(length(c.tipDiameter, c)), library \(length(l.tipDiameter, l))") }
        if c.fluteLength != l.fluteLength { parts.append("flute length") }
        if c.stepdown != l.stepdown { parts.append("stepdown \(length(c.stepdown, c)), library \(length(l.stepdown, l))") }
        if c.stepover != l.stepover { parts.append("stepover \(length(c.stepover, c)), library \(length(l.stepover, l))") }
        if c.spindleRPM != l.spindleRPM { parts.append("spindle \(number(c.spindleRPM)) rpm, library \(number(l.spindleRPM)) rpm") }
        if c.feedRate != l.feedRate { parts.append("feed rate \(number(c.feedRate)), library \(number(l.feedRate))") }
        if c.plungeRate != l.plungeRate { parts.append("plunge rate \(number(c.plungeRate)), library \(number(l.plungeRate))") }
        if c.materials != l.materials { parts.append("cutting data per material") }
        if c.shape != l.shape { parts.append("shape") }
        if parts.isEmpty { return "other settings" }
        return parts.prefix(3).joined(separator: "; ") + (parts.count > 3 ? "; and more" : "")
    }
}
