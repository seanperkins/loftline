import CAMCore
import Foundation

/// A post whose tool change does not set Z for the new bit gives the program no way to resume at the right height: one that
/// only stops (M0: the GRBL, LinuxCNC, Onefinity Buildbotics and UCCNC posts; LinuxCNC cannot touch off while paused), or
/// whose controller's M6 changes the tool without applying its length (`BuiltInPosts.toolChangeKeepsZIDs`: MASSO, Centroid).
/// A program that changes to a second tool with such a post gets a warning. A post sets Z when it probes on a touch plate,
/// applies a tool length offset, or hands the change to an M6 that sets it (the Avid's Mach4 macro, the Othermill's software).
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
            "This program changes tools \(changes - 1) time\(changes == 2 ? "" : "s"), and the post \"\(profile.name)\" does not set Z "
            + "for the new bit (it stops, or changes tools without a tool length), so the program resumes at the old Z zero. "
            + "Save one file per tool (Toolpaths > Save All Toolpaths), and load and touch off each tool before starting its file.")
    }

    private static func setsZ(_ p: PostProfile) -> Bool {
        if case .on? = p.toolChangeProbe { return true }
        if p.useToolLengthOffset { return true }
        if let family = BuiltInPosts.family(of: p.id), BuiltInPosts.toolChangeKeepsZIDs.contains(family) { return false }
        return GCodeParser.parse(p.toolChange.joined(separator: "\n")).blocks.contains { $0.has("M", 6) }
    }
}
