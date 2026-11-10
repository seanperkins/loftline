import Foundation
import LoftLineKit

public struct AssistantAccessError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Checks every path an assistant names against the allowed folders, by its real location: links are followed and `..` is
/// refused, so neither leads out. Writes are checked again on the folder actually opened (`fileOperations`). The folder list is
/// read again on every call, so a folder the user adds or removes counts at once, without restarting the server.
public struct AssistantAccess {
    private let source: () -> AssistantSettings
    /// The settings file, named when nothing is allowed.
    private let settingsFile: URL?
    /// Documents/LoftLine, made on first use.
    public let defaultFolder: URL

    /// Fixed settings (tests, and callers that hold their own).
    public init(settings: AssistantSettings, defaultFolder: URL = AssistantSettings.defaultFolder) {
        source = { settings }
        settingsFile = nil
        self.defaultFolder = defaultFolder
    }

    /// The settings in `settingsFile`, read again on every call (the server's).
    public init(settingsFile: URL = AssistantSettings.fileURL, defaultFolder: URL = AssistantSettings.defaultFolder) {
        source = { AssistantSettings.load(from: settingsFile) }
        self.settingsFile = settingsFile
        self.defaultFolder = defaultFolder
    }

    public var settings: AssistantSettings { source() }

    /// The real location of a path: links followed in the part that exists (what doesn't exist yet can't be a link).
    static func realPath(_ url: URL) -> URL {
        var existing = url.standardizedFileURL, rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var real = existing.resolvingSymlinksInPath().standardizedFileURL
        for part in rest { real.appendPathComponent(part) }
        return real
    }

    /// The real location of `path`, inside an allowed folder. A relative path is taken inside the first allowed folder.
    public func resolve(_ path: String) throws -> URL {
        let first = settings.allowedFolders.first.map { URL(fileURLWithPath: $0) } ?? defaultFolder
        let url = path.hasPrefix("/") || path.hasPrefix("~") || Self.isWindowsAbsolute(path)
            ? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            : first.appendingPathComponent(path)
        guard !url.pathComponents.contains("..") else {
            throw AssistantAccessError(message: "\(path) uses \"..\"; give the full path inside an allowed folder.")
        }
        let real = Self.realPath(url)
        try check(real, asked: path)
        return real
    }

    /// Throws unless `url` (a real path) is an allowed folder or inside one.
    public func check(_ url: URL, asked: String? = nil) throws {
        let current = settings
        guard !current.allowedFolders.isEmpty else {
            throw AssistantAccessError(message: "No folders are allowed for assistants"
                + (settingsFile.map { " (\($0.path) is empty, or couldn't be read)" } ?? "")
                + ". Add one in LoftLine: Help > Connect an AI Assistant.")
        }
        for folder in current.allowedFolders {
            let root = Self.realPath(URL(fileURLWithPath: folder))
            if Self.isInside(url.standardizedFileURL, root: root, caseSensitive: Self.isCaseSensitive(root)) { return }
        }
        let list = current.allowedFolders.joined(separator: ", ")
        throw AssistantAccessError(message: "\(asked ?? url.path) is outside the folders LoftLine lets assistants use (\(list)). "
            + "Add the folder in LoftLine: Help > Connect an AI Assistant.")
    }

    /// The writer's file operations, with every folder it opens checked by the real path it opened, and the default folder made
    /// when an assistant first writes there.
    public func fileOperations(base: GCodeFileSet.FileOperations = .live) -> GCodeFileSet.FileOperations {
        var ops = base
        let access = self
        ops.openFolder = { url in
            if url.standardizedFileURL.path == Self.realPath(access.defaultFolder).path, (try? access.check(url)) != nil {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            let folder = try base.openFolder(url)
            try access.check(Self.realPath(folder.url), asked: url.path)
            return folder
        }
        return ops
    }

    /// True when `url` is `root` or inside it, comparing names as the volume does.
    public static func isInside(_ url: URL, root: URL, caseSensitive: Bool) -> Bool {
        let parts = url.standardizedFileURL.pathComponents, base = root.standardizedFileURL.pathComponents
        guard parts.count >= base.count else { return false }
        return zip(parts, base).allSatisfy { caseSensitive ? $0 == $1 : $0.lowercased() == $1.lowercased() }
    }

    /// Whether the volume holding `root` tells names apart by case. Unknown counts as case-sensitive: an exact comparison can
    /// only refuse, never let a different folder through.
    static func isCaseSensitive(_ root: URL) -> Bool {
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        #if os(Windows)
        return false
        #else
        return (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? true
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
