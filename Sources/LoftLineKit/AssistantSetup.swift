import Foundation

/// What Help > Connect an AI Assistant… shows, on the Mac and in the desktop app: where the server is and the settings to paste
/// into an assistant. Nothing here writes an assistant's own settings (MCP spec, "Setup for users").
public enum AssistantSetup {
    /// The arguments that tell the server the app's version, where it can't read it itself (off the Mac). Only a plain version
    /// string is passed on, so nothing pasted into a shell carries anything else.
    static func versionArguments(_ version: String?) -> [String] {
        guard let v = version, !v.isEmpty, v.count <= 40,
              v.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".+-_".unicodeScalars.contains($0) })
        else { return [] }
        return ["--version", v]
    }

    /// For Claude Desktop and most assistants: their `mcpServers` setting.
    public static func config(serverPath: String, version: String? = nil) -> String {
        var server: [String: Any] = ["command": serverPath]
        let args = versionArguments(version)
        if !args.isEmpty { server["args"] = args }
        let object: [String: Any] = ["mcpServers": ["loftline": server]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// For Claude Code: one command to paste into a terminal. The path is quoted so the shell runs nothing in it: single quotes
    /// for a Mac or Linux shell (a quote inside becomes '\''), double quotes on Windows, where paths can't hold one.
    public static func claudeCodeLine(serverPath: String, version: String? = nil) -> String {
        let args = versionArguments(version).map { " " + $0 }.joined()
        #if os(Windows)
        return "claude mcp add loftline -- \"\(serverPath)\"" + args
        #else
        return "claude mcp add loftline -- '" + serverPath.replacingOccurrences(of: "'", with: "'\\''") + "'" + args
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
