import Foundation
import LoftLineKit

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

public struct AssistantAccessError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Checks every path an assistant names against the allowed folders, by its real location: links are followed and `..` is
/// refused, so neither leads out. Writes are checked again on the folder actually opened (`fileOperations`).
public struct AssistantAccess {
    public let settings: AssistantSettings

    public init(settings: AssistantSettings) { self.settings = settings }

    /// The allowed folders by their real paths (an allowed folder that is itself a link counts as where it points).
    var allowedRoots: [URL] { settings.allowedFolders.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL } }

    /// The real location of `path`, inside an allowed folder. A relative path is taken inside the first allowed folder.
    public func resolve(_ path: String) throws -> URL {
        let first = settings.allowedFolders.first.map { URL(fileURLWithPath: $0) } ?? AssistantSettings.defaultFolder
        let url = path.hasPrefix("/") || path.hasPrefix("~") || Self.isWindowsAbsolute(path)
            ? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            : first.appendingPathComponent(path)
        guard !url.pathComponents.contains("..") else {
            throw AssistantAccessError(message: "\(path) uses \"..\"; give the full path inside an allowed folder.")
        }
        // Follow links in the part that exists; what doesn't exist yet can't be a link.
        var existing = url.standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var real = existing.resolvingSymlinksInPath()
        for part in rest { real.appendPathComponent(part) }
        try check(real, asked: path)
        return real
    }

    /// Throws unless `url` (a real path) is an allowed folder or inside one.
    public func check(_ url: URL, asked: String? = nil) throws {
        let parts = Self.components(url.standardizedFileURL)
        for root in allowedRoots {
            let base = Self.components(root)
            if parts.count >= base.count, Array(parts.prefix(base.count)) == base { return }
        }
        let list = settings.allowedFolders.joined(separator: ", ")
        throw AssistantAccessError(message: "\(asked ?? url.path) is outside the folders LoftLine lets assistants use (\(list)). "
            + "Add the folder in LoftLine: Help > Connect an AI Assistant.")
    }

    /// The writer's file operations, with every folder it opens checked by the real path it opened, and the default folder made
    /// when an assistant first writes there.
    public func fileOperations(base: GCodeFileSet.FileOperations = .live) -> GCodeFileSet.FileOperations {
        var ops = base
        let access = self
        ops.openFolder = { url in
            if url.standardizedFileURL.path == AssistantSettings.defaultFolder.standardizedFileURL.path,
               access.settings.allowedFolders.contains(AssistantSettings.defaultFolder.path) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let folder = try base.openFolder(url)
            try access.check(folder.url.resolvingSymlinksInPath(), asked: url.path)
            return folder
        }
        return ops
    }

    /// Path components compared as the file system does: without case on the Mac and Windows.
    static func components(_ url: URL) -> [String] {
        #if os(Linux)
        return url.pathComponents
        #else
        return url.pathComponents.map { $0.lowercased() }
        #endif
    }

    static func isWindowsAbsolute(_ path: String) -> Bool {
        #if os(Windows)
        return path.count > 2 && path.dropFirst().first == ":" || path.hasPrefix("\\\\")
        #else
        return false
        #endif
    }
}
