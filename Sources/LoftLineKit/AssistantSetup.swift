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

    /// For Claude Code: one command to paste into a terminal. The path is quoted so the shell runs nothing in it: single quotes
    /// for a Mac or Linux shell (a quote inside becomes '\''), double quotes on Windows, where paths can't hold one.
    public static func claudeCodeLine(serverPath: String) -> String {
        #if os(Windows)
        return "claude mcp add loftline -- \"\(serverPath)\""
        #else
        return "claude mcp add loftline -- '" + serverPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        #endif
    }

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
