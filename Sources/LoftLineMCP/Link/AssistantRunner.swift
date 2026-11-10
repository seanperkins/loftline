import Foundation
import CAMCore
import LoftLineKit

/// Runs one tool on a copy of a window, for the Mac app and the desktop engine alike (spec 2, "Architecture"). The tools are built
/// over the copy for each call, since every tool closes over its service's session. Nothing comes back but the output and the
/// copy's project, which a host applies as one Undo step when the tool was an edit.
public enum AssistantRunner {
    public struct UnknownTool: LocalizedError {
        public var tool: String
        public var errorDescription: String? { "LoftLine has no tool \"\(tool)\"." }
    }

    public static func run(tool: String, arguments: [String: Any], snapshot: CoreSnapshot,
                           access: AssistantAccess) throws -> (output: ToolOutput, project: LoftLineProject) {
        let session = CoreSession(snapshot: snapshot)
        let tools = AssistantTools.all(service: CoreService(session: session), access: access)
        guard let found = tools.first(where: { $0.name == tool }) else { throw UnknownTool(tool: tool) }
        let output = try found.call(arguments)
        return (output, session.project)
    }

    /// `calculate`'s answer for a window, from a snapshot taken after the window's own calculation.
    public static func calculationReply(snapshot: CoreSnapshot, ids: [UUID]) -> ToolOutput {
        ToolpathTools.calculationReply(session: CoreSession(snapshot: snapshot), ids: ids)
    }
}
