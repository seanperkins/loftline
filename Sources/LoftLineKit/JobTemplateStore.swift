import CADCore
import CAMCore
import Foundation

/// Job templates: ordinary `.loftline` projects (job setup, layers, vectors, toolpaths, post)
/// kept in ~/Library/Application Support/LoftLine/templates/. A new document made from a template
/// is an untitled copy, so the template file itself is never overwritten by Save.
public struct JobTemplateStore {
    public struct Entry: Equatable, Identifiable {
        public var name: String
        public var url: URL
        public var id: URL { url }
    }

    public var directory: URL

    public init(directory: URL = ToolLibraryStore.supportDirectory.appendingPathComponent("templates", isDirectory: true)) {
        self.directory = directory
    }

    public func templates() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == LoftLineProject.fileExtension }
            .map { Entry(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes `project` as template `name` (replacing one with the same name).
    @discardableResult
    public func save(_ project: LoftLineProject, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = Self.fileSafe(name)
        let url = directory.appendingPathComponent(clean).appendingPathExtension(LoftLineProject.fileExtension)
        var p = project
        p.document.name = clean
        try p.encoded().write(to: url, options: .atomic)
        return url
    }

    /// The project a new document starts from: the template's content under a fresh name.
    public func instantiate(_ entry: Entry) throws -> LoftLineProject {
        var p = try LoftLineProject.opening(from: Data(contentsOf: entry.url))
        p.document.name = "Untitled"
        return p
    }

    public static func fileSafe(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = CharacterSet(charactersIn: "/:\\")
        let s = String(trimmed.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) })
        return s.isEmpty ? "Template" : s
    }
}
