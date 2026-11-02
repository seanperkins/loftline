import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

@Suite struct RecoveryTests {
    func makeDoc() -> LoftLineDocument {
        LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
    }

    @Test func storeWritesListsAndRemoves() throws {
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        #expect(store.entries().isEmpty)
        let a = RecoveryEntry(id: UUID(), name: "Old", savedAt: Date(timeIntervalSince1970: 1000))
        let b = RecoveryEntry(id: UUID(), name: "New", savedAt: Date(timeIntervalSince1970: 2000))
        let project = AppTestSupport.project()
        try store.write(project, entry: a)
        try store.write(LoftLineProject(), entry: b)
        #expect(store.entries().map(\.name) == ["New", "Old"])
        #expect(try store.project(for: a.id) == project)
        store.remove(a.id)
        #expect(store.entries().map(\.id) == [b.id])
    }

    @Test func archiveMovesAndPrunes() throws {
        var store = RecoveryStore(directory: AppTestSupport.tempDir())
        store.archiveLimit = 2
        var ids: [UUID] = []
        for i in 0..<3 {
            let e = RecoveryEntry(id: UUID(), name: "D\(i)", savedAt: Date())
            try store.write(LoftLineProject(), entry: e)
            ids.append(e.id)
            store.archive(e.id)
        }
        #expect(store.entries().isEmpty)
        #expect(store.archivedProjects().count == 2)
    }

    @Test func coordinatorWritesOnlyDirtyDocuments() throws {
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let c = RecoveryCoordinator(store: store)
        let doc = makeDoc()
        c.register(doc)
        c.tick()
        #expect(store.entries().isEmpty)  // nothing changed since open

        doc.perform("Rename") { $0.document.name = "Edited" }
        c.tick()
        #expect(store.entries().map(\.name) == ["Edited"])
        #expect(try store.project(for: doc.recoveryID) == doc.project)

        // A save that reached the file makes it clean again: the copy is removed on the next tick.
        let url = AppTestSupport.tempDir().appendingPathComponent("saved.loftline")
        doc.fileURL = url
        let snap = try doc.snapshot(contentType: .loftlineProject)
        try doc.fileData(for: snap).write(to: url)
        c.tick()                                  // looks at the file
        #expect(!doc.needsRecovery)
        #expect(store.entries().isEmpty)
    }

    @Test func closingWindowOrQuittingRemovesOwnCopiesOnly() throws {
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let leftover = RecoveryEntry(id: UUID(), name: "From a crash", savedAt: Date())
        try store.write(LoftLineProject(), entry: leftover)
        let c = RecoveryCoordinator(store: store)
        let a = makeDoc(), b = makeDoc()
        c.register(a); c.register(b)
        a.perform("A") { $0.document.name = "A" }
        b.perform("B") { $0.document.name = "B" }
        c.tick()
        #expect(store.entries().count == 3)
        c.unregister(a)
        #expect(Set(store.entries().map(\.name)) == ["B", "From a crash"])
        c.cleanUpOnQuit()
        #expect(store.entries().map(\.id) == [leftover.id])
    }

    @Test func undoBackToSavedStateIsClean() {
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        um.beginUndoGrouping(); doc.perform("Rename") { $0.document.name = "X" }; um.endUndoGrouping()
        #expect(doc.needsRecovery)
        um.undo()
        #expect(!doc.needsRecovery)
    }
}

/// Issue #123: a copy whose metadata was never written or cannot be read is still offered.
@Suite struct RecoveryWithoutMetadataTests {
    func store() -> RecoveryStore {
        let s = RecoveryStore(directory: AppTestSupport.tempDir())
        try? FileManager.default.createDirectory(at: s.directory, withIntermediateDirectories: true)
        return s
    }

    func metaURL(_ s: RecoveryStore, _ id: UUID) -> URL {
        s.directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func date(_ url: URL) throws -> Date {
        try #require(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    @Test func aCopyWithNoMetadataIsListed() throws {
        let s = store(), id = UUID()
        try LoftLineProject().encoded().write(to: s.projectURL(id))
        let e = s.entries()
        #expect(e.map(\.id) == [id])
        #expect(e.first?.name == "Unsaved document")
        #expect(e.first?.savedAt == (try date(s.projectURL(id))))
    }

    @Test func unreadableOrForeignMetadataFallsBack() throws {
        let s = store()
        let broken = UUID(), foreign = UUID()
        try s.write(LoftLineProject(), entry: RecoveryEntry(id: broken, name: "Broken", savedAt: Date()))
        try Data("not json".utf8).write(to: metaURL(s, broken))
        try s.write(LoftLineProject(), entry: RecoveryEntry(id: foreign, name: "Foreign", savedAt: Date()))
        let other = try JSONEncoder.iso8601.encode(RecoveryEntry(id: UUID(), name: "Other", savedAt: Date()))
        try other.write(to: metaURL(s, foreign))
        let e = s.entries()
        #expect(Set(e.map(\.id)) == [broken, foreign] && e.count == 2)
        #expect(e.allSatisfy { $0.name == "Unsaved document" })
    }

    @Test func onlyRegularUpperCaseUUIDCopiesAreListed() throws {
        let s = store(), lower = UUID()
        let data = try LoftLineProject().encoded()
        try data.write(to: s.directory.appendingPathComponent(lower.uuidString.lowercased() + ".loftline"))
        try data.write(to: s.directory.appendingPathComponent("notes.loftline"))
        try data.write(to: s.directory.appendingPathComponent(".tmp-\(UUID().uuidString).loftline"))
        try FileManager.default.createDirectory(at: s.projectURL(UUID()), withIntermediateDirectories: true)
        try JSONEncoder.iso8601.encode(RecoveryEntry(id: UUID(), name: "Alone", savedAt: Date()))
            .write(to: metaURL(s, UUID()))
        #expect(s.entries().isEmpty)
    }

    @Test func aCopyWithoutMetadataSortsByItsDate() throws {
        let s = store()
        let old = RecoveryEntry(id: UUID(), name: "Old", savedAt: Date(timeIntervalSinceNow: -3600))
        let new = RecoveryEntry(id: UUID(), name: "New", savedAt: Date(timeIntervalSinceNow: 3600))
        try s.write(LoftLineProject(), entry: old)
        try s.write(LoftLineProject(), entry: new)
        try LoftLineProject().encoded().write(to: s.projectURL(UUID()))   // modified now: between the two
        #expect(s.entries().map(\.name) == ["New", "Unsaved document", "Old"])
    }

    @Test func aCopyWithoutMetadataIsArchivedAndRemoved() throws {
        let s = store(), a = UUID(), b = UUID()
        try LoftLineProject().encoded().write(to: s.projectURL(a))
        try LoftLineProject().encoded().write(to: s.projectURL(b))
        s.archive(a)
        s.remove(b)
        #expect(s.entries().isEmpty)
        #expect(s.archivedProjects().map { $0.deletingPathExtension().lastPathComponent } == [a.uuidString])
    }

    /// The coordinator owns a copy before writing it, so a write that fails halfway (here the metadata, blocked by a
    /// directory, after the project was written) is not offered as another session's work and is cleaned up when the
    /// window closes.
    @Test func aHalfWrittenCopyIsOwnedAndCleanedUp() throws {
        let s = store()
        let c = RecoveryCoordinator(store: s)
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        c.register(doc)
        try FileManager.default.createDirectory(at: metaURL(s, doc.recoveryID), withIntermediateDirectories: true)
        doc.perform("Rename") { $0.document.name = "Edited" }
        c.tick()                                                   // the project is written, its metadata write fails
        #expect(FileManager.default.fileExists(atPath: s.projectURL(doc.recoveryID).path))
        #expect(c.ownedIDs.contains(doc.recoveryID))
        c.unregister(doc)                                          // the window closes
        #expect(!FileManager.default.fileExists(atPath: s.projectURL(doc.recoveryID).path))
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
