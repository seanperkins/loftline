import CAMCore
import Foundation

/// Built-in controllers' own limits, checked at export beside `ToolChangeZ` (#104, #105, #114): coolant on a controller that
/// has none. Keyed by built-in id, which a project's copy keeps.
public enum DialectChecks {
    public static func issues(toolpaths: [Toolpath], profile: PostProfile) -> [GCodeIssue] {
        guard BuiltInPosts.noCoolantIDs.contains(profile.id) else { return [] }
        var seen = Set<String>()
        let cooled = toolpaths.filter { $0.coolant != nil }.map(\.name).filter { seen.insert($0).inserted }
        guard !cooled.isEmpty else { return [] }
        let reason = OthermillSetup.postIDs.contains(profile.id)
            ? "The Othermill has no coolant, and its G-code reference lists M7, M8 and M9 as unsupported"
            : "Carbide Motion ignores M7 and does not support M8"
        return [GCodeIssue(severity: .error, message: "\(reason): turn coolant off for \(cooled.joined(separator: ", ")).")]
    }
}
