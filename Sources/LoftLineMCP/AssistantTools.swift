import Foundation
import LoftLineKit

/// Every tool the server offers, in a fixed order (MCP spec, "The tools").
public enum AssistantTools {
    public static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        ProjectTools.all(service: service, access: access) + DesignTools.all(service: service, access: access)
            + ToolpathTools.all(service: service, access: access) + OutputTools.all(service: service, access: access)
            + PreviewTool.all(service: service) + HelpTool.all()
    }

    /// What the server offers: every tool, routed to the open window while in document mode, and the two tools that pick it
    /// (spec 2, "The server"). `new_project` and `open_project` go back to file mode; `undo` stays the user's.
    public static func server(service: CoreService, access: AssistantAccess, link: DocumentMode) -> [AssistantTool] {
        let routed = all(service: service, access: access).map { tool -> AssistantTool in
            AssistantTool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema) { args in
                guard link.isActive else { return try tool.call(args) }
                switch tool.name {
                case "new_project", "open_project":
                    link.leave()
                    return try tool.call(args)
                case "undo":
                    throw ToolError("Undo is yours: Edit ▸ Undo in LoftLine takes back the assistant's steps.")
                default:
                    return try link.call(tool.name, args)
                }
            }
        }
        return routed + DocumentTools.all(link: link)
    }
}

