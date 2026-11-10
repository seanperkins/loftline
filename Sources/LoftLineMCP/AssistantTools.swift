import Foundation
import LoftLineKit

/// Every tool the server offers, in a fixed order (MCP spec, "The tools").
public enum AssistantTools {
    public static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] {
        ProjectTools.all(service: service, access: access) + DesignTools.all(service: service, access: access)
            + ToolpathTools.all(service: service, access: access) + OutputTools.all(service: service, access: access)
    }
}
