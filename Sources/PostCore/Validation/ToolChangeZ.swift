import CAMCore
import Foundation

/// A post whose tool change only stops (M0, as the GRBL and LinuxCNC posts do) gives the operator no way to set Z for the new
/// bit: LinuxCNC cannot touch off while a program is paused, and the program resumes at the old Z zero. A program that changes
/// to a second tool with such a post gets a warning. A post sets Z when it probes on a touch plate, applies a tool length
/// offset, or hands the change to the controller's M6 (the Avid's Mach4 macro).
public enum ToolChangeZ {
    public static func warning(toolpaths: [Toolpath], profile: PostProfile) -> GCodeIssue? {
        var changes = 0
        var current: UUID?
        for tp in toolpaths where tp.tool.id != current {
            changes += 1
            current = tp.tool.id
        }
        guard changes > 1, !setsZ(profile) else { return nil }
        return GCodeIssue(severity: .warning, message:
            "This program changes tools \(changes - 1) time\(changes == 2 ? "" : "s"), and the post \"\(profile.name)\" only stops "
            + "for a tool change, so Z cannot be set for the new bit and the program resumes at the old Z zero. "
            + "Save one file per tool (Toolpaths > Save All Toolpaths), and load and touch off each tool before starting its file.")
    }

    private static func setsZ(_ p: PostProfile) -> Bool {
        if case .on? = p.toolChangeProbe { return true }
        if p.useToolLengthOffset { return true }
        return GCodeParser.parse(p.toolChange.joined(separator: "\n")).blocks.contains { $0.has("M", 6) }
    }
}
