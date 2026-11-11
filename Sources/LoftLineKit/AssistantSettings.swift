import Foundation

/// The folders an AI assistant may read and write through LoftLine. Kept in `assistant.json` in LoftLine's support folder and
/// edited from Help > Connect an AI Assistant… (Mac and desktop); with no file, `Documents/LoftLine` (MCP spec, "Safety").
public struct AssistantSettings: Codable, Equatable {
    public var allowedFolders: [String]
    /// "Let assistants edit open documents": the app listens for the live link only while this is on. A convenience, not the
    /// security control (an assistant with a shell can write this file); the Allow click in the window is (spec 2, "The switch").
    public var liveLink: Bool

    public init(allowedFolders: [String], liveLink: Bool = false) {
        self.allowedFolders = allowedFolders
        self.liveLink = liveLink
    }

    private enum CodingKeys: String, CodingKey { case allowedFolders, liveLink }

    /// A file written before the switch existed keeps its folders and reads as off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedFolders = try c.decode([String].self, forKey: .allowedFolders)
        liveLink = try c.decodeIfPresent(Bool.self, forKey: .liveLink) ?? false
    }

    /// The live link's socket folder: `link/` beside the settings file, so `LOFTLINE_ASSISTANT_SETTINGS` moves it too.
    public static func linkFolder(for settingsFile: URL = fileURL) -> URL {
        settingsFile.deletingLastPathComponent().appendingPathComponent("link", isDirectory: true)
    }

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

    /// The saved settings. No file gives the default folder alone; a file that is there but can't be read or decoded allows
    /// nothing, so a damaged list never widens what an assistant can reach.
    public static func load(from url: URL = fileURL) -> AssistantSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AssistantSettings(allowedFolders: [defaultFolder.path]) }
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AssistantSettings.self, from: data) else {
            return AssistantSettings(allowedFolders: [])
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
