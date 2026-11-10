import Foundation

/// The folders an AI assistant may read and write through LoftLine. Kept in `assistant.json` in LoftLine's support folder, where
/// the Mac's Preferences and the desktop app's settings edit it; with no file, `Documents/LoftLine` (MCP spec, "Safety").
public struct AssistantSettings: Codable, Equatable {
    public var allowedFolders: [String]

    public init(allowedFolders: [String]) { self.allowedFolders = allowedFolders }

    /// Documents/LoftLine, created the first time an assistant writes there.
    public static var defaultFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("LoftLine", isDirectory: true)
    }

    /// `assistant.json` beside `tools.json` in LoftLine's support folder; `LOFTLINE_ASSISTANT_SETTINGS` names another file
    /// (the smoke test uses it).
    public static var fileURL: URL {
        if let path = ProcessInfo.processInfo.environment["LOFTLINE_ASSISTANT_SETTINGS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LoftLine/assistant.json")
    }

    /// The saved settings; a missing or unreadable file gives the default folder alone.
    public static func load(from url: URL = fileURL) -> AssistantSettings {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AssistantSettings.self, from: data) else {
            return AssistantSettings(allowedFolders: [defaultFolder.path])
        }
        return s
    }

    public func save(to url: URL = AssistantSettings.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
