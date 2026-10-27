import CADCore
import CAMCore
import Combine
import Foundation

/// One recoverable snapshot of an unsaved document.
struct RecoveryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var savedAt: Date
}

/// Crash-recovery copies of unsaved documents in
/// ~/Library/Application Support/LoftLine/Recovery/<id>.loftline (+ <id>.json metadata). Recovered or
/// discarded copies move to Recovery/Archive (newest `archiveLimit` kept), so nothing is lost
/// by a wrong click.
struct RecoveryStore {
    var directory: URL
    var archiveLimit = 20

    init(directory: URL = ToolLibraryStore.supportDirectory.appendingPathComponent("Recovery", isDirectory: true)) {
        self.directory = directory
    }

    var archiveDirectory: URL { directory.appendingPathComponent("Archive", isDirectory: true) }

    func projectURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("loftline") }
    private func metaURL(_ id: UUID, in dir: URL? = nil) -> URL {
        (dir ?? directory).appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func write(_ project: LoftLineProject, entry: RecoveryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try project.encoded().write(to: projectURL(entry.id), options: .atomic)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(entry).write(to: metaURL(entry.id), options: .atomic)
    }

    /// Entries with a readable snapshot, newest first.
    func entries() -> [RecoveryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(RecoveryEntry.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: projectURL($0.id).path) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func project(for id: UUID) throws -> LoftLineProject {
        try LoftLineProject.opening(from: Data(contentsOf: projectURL(id)))
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: projectURL(id))
        try? FileManager.default.removeItem(at: metaURL(id))
    }

    /// Moves an entry into the archive and prunes old archived copies.
    func archive(_ id: UUID) {
        let fm = FileManager.default
        try? fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        for (src, ext) in [(projectURL(id), "loftline"), (metaURL(id), "json")] {
            let dst = archiveDirectory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        pruneArchive()
    }

    func archivedProjects() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: archiveDirectory,
                                                                  includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension == "loftline" }.sorted { date($0) > date($1) }
    }

    private func pruneArchive() {
        for old in archivedProjects().dropFirst(archiveLimit) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("json"))
        }
    }
}

/// Keeps a recovery copy of every open document that has unsaved changes. Copies are written on
/// a timer (Preferences interval), removed when the document is saved or its window closes, and
/// all of this session's copies are removed on a normal quit. Copies left behind mean LoftLine did
/// not quit normally; they are offered at the next launch.
final class RecoveryCoordinator {
    static let shared = RecoveryCoordinator(store: RecoveryStore())

    let store: RecoveryStore
    private struct WeakDoc { weak var doc: LoftLineDocument? }
    private var docs: [UUID: WeakDoc] = [:]
    /// Copies written by this session (only these are cleaned up on quit).
    private(set) var ownedIDs: Set<UUID> = []
    /// Last project written per document, to skip identical rewrites.
    private var written: [UUID: LoftLineProject] = [:]
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    init(store: RecoveryStore) { self.store = store }

    func register(_ doc: LoftLineDocument) { docs[doc.recoveryID] = WeakDoc(doc: doc) }

    /// Window closed normally: its copy is no longer needed.
    func unregister(_ doc: LoftLineDocument) {
        docs[doc.recoveryID] = nil
        discard(doc.recoveryID)
    }

    /// Writes copies of dirty documents and removes copies of clean or closed ones.
    func tick(now: Date = Date()) {
        for (id, ref) in docs {
            guard let doc = ref.doc else { docs[id] = nil; discard(id); continue }
            doc.confirmSave()   // a save the system has written since the last look makes the document clean
            if doc.needsRecovery {
                guard written[id] != doc.project else { continue }
                let entry = RecoveryEntry(id: id, name: doc.document.name, savedAt: now)
                do {
                    try store.write(doc.project, entry: entry)
                    written[id] = doc.project
                    ownedIDs.insert(id)
                } catch {
                    NSLog("LoftLine: could not write recovery copy: \(error.localizedDescription)")
                }
            } else {
                discard(id)
            }
        }
    }

    /// Normal quit: remove this session's copies (the user already chose to save or discard).
    func cleanUpOnQuit() {
        for id in ownedIDs { store.remove(id) }
        ownedIDs = []
        written = [:]
    }

    private func discard(_ id: UUID) {
        guard ownedIDs.contains(id) else { return }
        store.remove(id)
        ownedIDs.remove(id)
        written[id] = nil
    }

    /// Starts the timer and follows the interval set in Preferences.
    func start(preferences: PreferencesModel = .shared) {
        schedule(seconds: preferences.prefs.recoveryIntervalSeconds)
        cancellable = preferences.$prefs.map(\.recoveryIntervalSeconds).removeDuplicates()
            .sink { [weak self] in self?.schedule(seconds: $0) }
    }

    private func schedule(seconds: Int) {
        timer?.invalidate()
        timer = nil
        guard seconds > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
}
