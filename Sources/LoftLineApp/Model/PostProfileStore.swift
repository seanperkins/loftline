import CADCore
import Darwin
import Foundation
import PostCore

/// A post file that did not load, and why (listed in Post Processors and by `loftline-cli`).
struct SkippedPost: Hashable, Sendable {
    var fileName: String
    var reason: String
}

/// Built-in post profiles plus user profiles stored as JSON in
/// ~/Library/Application Support/LoftLine/posts/<id>.json (a user file with a built-in's id overrides it).
struct PostProfileStore {
    var directory: URL
    /// False = the built-ins only, whatever is in `directory` (the command line's `--builtin-only`).
    var readsUserFiles = true
    /// How Delete removes a file: to the Trash, so a post (machine output) can be recovered. Tests pass their own.
    var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    init(directory: URL = ToolLibraryStore.supportDirectory.appendingPathComponent("posts", isDirectory: true)) {
        self.directory = directory
    }

    static let defaultProfileID = BuiltInPosts.avidMach4Inch.id

    /// An id that is a single, plain file name: letters, digits, `.`, `_`, `-`, not starting with a dot.
    static func isSafeID(_ id: String) -> Bool {
        guard let first = id.first, first != "." else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    func fileURL(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }

    private func jsonFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One scan of the folder: the posts that load (built-ins, overridden by a user file of the same id) and the files that
    /// do not, with the reason. The file name is checked first and only a loaded file claims an id, so Finder's
    /// "x copy.json" holding id "x" is listed and "x.json" still loads.
    func load() -> (profiles: [PostProfile], skipped: [SkippedPost]) {
        guard readsUserFiles else { return (BuiltInPosts.all, []) }
        var user: [PostProfile] = []
        var skipped: [SkippedPost] = []
        var claimed = Set<String>()
        for url in jsonFiles() {
            let name = url.lastPathComponent
            func skip(_ reason: String) { skipped.append(SkippedPost(fileName: name, reason: reason)) }
            let profile: PostProfile
            do {
                profile = try PostProfile.fromJSON(Data(contentsOf: url))
            } catch let e as SnapshotError {
                skip(e.errorDescription ?? "\(e)"); continue
            } catch {
                skip(error.localizedDescription); continue
            }
            guard Self.isSafeID(profile.id) else {
                skip("its id \"\(profile.id)\" is not a plain file name (letters, digits, . _ -)"); continue
            }
            guard name == "\(profile.id).json" else {
                skip("a post file must be named after its id: \(profile.id).json"); continue
            }
            guard claimed.insert(profile.id).inserted else { skip("another file already has the id \"\(profile.id)\""); continue }
            var p = profile
            if p.pause?.isEmpty == true { p.pause = nil }   // an empty pause template stops nothing: it means the default
            user.append(p)
        }
        let userIDs = Set(user.map(\.id))
        return (BuiltInPosts.all.filter { !userIDs.contains($0.id) } + user, skipped)
    }

    func allProfiles() -> [PostProfile] { load().profiles }

    func profile(id: String?) -> PostProfile {
        let all = allProfiles()
        return all.first { $0.id == id } ?? all.first { $0.id == Self.defaultProfileID } ?? BuiltInPosts.avidMach4Inch
    }

    /// Default profile for a document's units (Avid inch/mm).
    static func defaultID(for units: LengthUnit) -> String {
        units == .inch ? BuiltInPosts.avidMach4Inch.id : BuiltInPosts.avidMach4MM.id
    }

    /// True when `id` is stored as a user file (editable and deletable).
    func isUserPost(_ id: String) -> Bool { FileManager.default.fileExists(atPath: fileURL(for: id).path) }

    /// A fresh id for a copy of `base`: an existing `-custom-<n>` suffix is dropped first, and every file name in the folder
    /// (whether it loads or not) and every built-in id is avoided, case-folded (the volume usually ignores case).
    func newID(from base: String) -> String {
        var stem = base
        if let r = stem.range(of: #"-custom-[0-9]+$"#, options: .regularExpression) { stem.removeSubrange(r) }
        let taken = Set(jsonFiles().map { $0.deletingPathExtension().lastPathComponent.lowercased() }
                        + BuiltInPosts.all.map { $0.id.lowercased() })
        if stem != base, !taken.contains(base.lowercased()) { return base }
        var n = 1
        while taken.contains("\(stem)-custom-\(n)".lowercased()) { n += 1 }
        return "\(stem)-custom-\(n)"
    }

    struct UnsafeID: LocalizedError {
        var id: String
        var errorDescription: String? { "The post id \"\(id)\" is not a plain file name." }
    }

    /// Saves an edit to a post: replaces its own file.
    @discardableResult
    func save(_ profile: PostProfile) throws -> URL {
        guard Self.isSafeID(profile.id) else { throw UnsafeID(id: profile.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: profile.id)
        try profile.toJSON().write(to: url, options: .atomic)
        return url
    }

    /// Saves a new post without ever replacing a file: created exclusively, and when the file now exists (another window
    /// saved a post with this id) under the next free id. Returns the post as saved.
    func saveNew(_ profile: PostProfile) throws -> PostProfile {
        guard Self.isSafeID(profile.id) else { throw UnsafeID(id: profile.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var p = profile
        for _ in 0..<1000 {
            let fd = open(fileURL(for: p.id).path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd < 0 {
                guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
                p.id = newID(from: p.id)
                continue
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: p.toJSON())
            try handle.close()
            return p
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Moves the post's file to the Trash (`trash`).
    func delete(id: String) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try trash(url)
    }
}
