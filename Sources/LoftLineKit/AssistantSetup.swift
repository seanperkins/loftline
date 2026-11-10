import Foundation

/// What Help > Connect an AI Assistant… shows, on the Mac and in the desktop app: where the server is and the settings to paste
/// into an assistant. Nothing here writes an assistant's own settings (MCP spec, "Setup for users").
public enum AssistantSetup {
    /// For Claude Desktop and most assistants: their `mcpServers` setting.
    public static func config(serverPath: String) -> String {
        let object: [String: Any] = ["mcpServers": ["loftline": ["command": serverPath]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// For Claude Code: one command to paste into a terminal.
    public static func claudeCodeLine(serverPath: String) -> String { "claude mcp add loftline -- \"\(serverPath)\"" }

    /// The server beside the app's own executable (`loftline-mcp`, or `.exe` on Windows).
    public static func serverPath(besideExecutable executable: URL) -> String {
        #if os(Windows)
        let name = "loftline-mcp.exe"
        #else
        let name = "loftline-mcp"
        #endif
        return executable.deletingLastPathComponent().appendingPathComponent(name).path
    }
}
