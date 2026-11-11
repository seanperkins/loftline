import Foundation

/// The review marker kept on disk (spec 2, "The review marker"): how many changes an assistant made to each file since the user
/// last clicked Dismiss. Kept in `review.json` beside `assistant.json`, keyed by the file's real path, so it survives autosave,
/// quitting and reopening, and saving. Only Dismiss clears it. A file moved or renamed outside LoftLine loses its record.
public struct ReviewMarkerStore {
    public let file: URL

    public init(file: URL = AssistantSettings.fileURL.deletingLastPathComponent().appendingPathComponent("review.json")) {
        self.file = file
    }

    struct Record: Codable { var changes: Int; var since: Date }

    static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    func save(_ records: [String: Record]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: file, options: .atomic)
    }

    public func count(for url: URL) -> Int { load()[Self.key(url)]?.changes ?? 0 }

    public func add(_ n: Int, for url: URL) throws {
        guard n > 0 else { return }
        var records = load()
        let k = Self.key(url)
        let old = records[k]
        records[k] = Record(changes: (old?.changes ?? 0) + n, since: old?.since ?? Date())
        try save(records)
    }

    /// Save As took the document to `to`: its record goes with it.
    public func move(from: URL, to: URL) throws {
        var records = load()
        guard let r = records.removeValue(forKey: Self.key(from)) else { return }
        let k = Self.key(to)
        records[k] = Record(changes: r.changes + (records[k]?.changes ?? 0), since: r.since)
        try save(records)
    }

    public func dismiss(_ url: URL) throws {
        var records = load()
        guard records.removeValue(forKey: Self.key(url)) != nil else { return }
        try save(records)
    }
}
