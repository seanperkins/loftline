import CADCore
import Foundation

/// One-time copy of Kerf's data into LoftLine's locations. It never modifies the old data, never overwrites a file or a
/// default LoftLine already has, and writes its completion flag last, so a failed run is simply run again.
///
/// Files: everything under `Application Support/Kerf` except `Recovery/`, with the project, tool-exchange and
/// toolpath-template extensions renamed. Defaults: every `kerf.*` key (and `NSWindow Frame Kerf.*` window frame) of the old
/// `com.seanperkins.kerf` domain, copied to the same name with `loftline.`. One of those keys, `kerf.groupByTool`, decides
/// how exported G-code is ordered, which is why it is a prefix rule and not a list.
public struct LegacyKerfMigration {
    public enum Outcome: Equatable {
        case notNeeded
        case completed
        case failed(String)
    }

    /// "done" once everything was copied (or there was nothing to copy); "skipped" when the user chose to continue without importing.
    public static let flagKey = "loftline.migratedFromKerf"
    public static let oldBundleID = "com.seanperkins.kerf"
    private static let extensions = ["kerf": "loftline", "kerftools": "loftlinetools", "kerftoolpaths": "loftlinetoolpaths"]

    public let oldSupport: URL
    public let newSupport: URL
    public let readOldDefaults: () -> [String: Any]?
    public let defaults: UserDefaults
    public let copy: (URL, URL) throws -> Void

    public init(oldSupport: URL, newSupport: URL, readOldDefaults: @escaping () -> [String: Any]?, defaults: UserDefaults,
         copy: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) {
        self.oldSupport = oldSupport
        self.newSupport = newSupport
        self.readOldDefaults = readOldDefaults
        self.defaults = defaults
        self.copy = copy
    }

    public func run() -> Outcome {
        if defaults.string(forKey: Self.flagKey) != nil { return .notNeeded }
        let hasOldFiles = FileManager.default.fileExists(atPath: oldSupport.path)
        let oldDefaults = readOldDefaults() ?? [:]
        if !hasOldFiles && oldDefaults.isEmpty {
            defaults.set("done", forKey: Self.flagKey)
            return .notNeeded
        }
        do {
            if hasOldFiles { try copyFiles() }
            copyDefaults(oldDefaults)
        } catch {
            return .failed(error.localizedDescription)
        }
        defaults.set("done", forKey: Self.flagKey)
        return .completed
    }

    /// The user chose to continue without importing: never ask again, leave the old data where it is.
    public func markSkipped() { defaults.set("skipped", forKey: Self.flagKey) }

    // MARK: Files

    private func copyFiles() throws {
        let fm = FileManager.default
        var sources: [(relative: String, url: URL)] = []
        // An enumerator over an unreadable directory yields nothing and raises nothing unless it is given an error handler, so the
        // walk reports its first error: a partial walk must never end in the completion flag.
        var walkError: Error?
        guard let walker = fm.enumerator(at: oldSupport, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles],
                                         errorHandler: { _, error in walkError = walkError ?? error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let base = oldSupport.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            if relative == "Recovery" { walker.skipDescendants(); continue }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                sources.append((relative, url))
            }
        }
        if let walkError { throw walkError }
        for (relative, src) in sources.sorted(by: { $0.relative < $1.relative }) {
            let dest = newSupport.appendingPathComponent(Self.renamed(relative))
            if fm.fileExists(atPath: dest.path) { continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Copy beside the destination under a temporary name and rename into place, so an interrupted copy can never leave a
            // partial file that a retry would take for a finished one.
            let temporary = dest.appendingPathExtension("migrating")
            try? fm.removeItem(at: temporary)
            do {
                try copy(src, temporary)
                try fm.moveItem(at: temporary, to: dest)
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
        }
    }

    private static func renamed(_ relative: String) -> String {
        let url = URL(fileURLWithPath: relative)
        guard let new = extensions[url.pathExtension.lowercased()] else { return relative }
        return url.deletingPathExtension().appendingPathExtension(new).relativePath
    }

    // MARK: Defaults

    private func copyDefaults(_ old: [String: Any]) {
        for (key, value) in old {
            guard let new = Self.newKey(for: key), defaults.object(forKey: new) == nil else { continue }
            defaults.set(value, forKey: new)
        }
    }

    public static func newKey(for old: String) -> String? {
        if old.hasPrefix("kerf.") { return "loftline." + old.dropFirst("kerf.".count) }
        let frame = "NSWindow Frame Kerf."
        if old.hasPrefix(frame) { return "NSWindow Frame LoftLine." + old.dropFirst(frame.count) }
        return nil
    }
}

extension LegacyKerfMigration {
    /// The real locations: the old `Kerf` folder beside LoftLine's support directory, and the old bundle id's defaults domain.
    public static func standard() -> LegacyKerfMigration {
        let newSupport = ToolLibraryStore.supportDirectory
        return LegacyKerfMigration(
            oldSupport: newSupport.deletingLastPathComponent().appendingPathComponent("Kerf", isDirectory: true),
            newSupport: newSupport,
            readOldDefaults: { UserDefaults.standard.persistentDomain(forName: oldBundleID) },
            defaults: .standard)
    }
}
