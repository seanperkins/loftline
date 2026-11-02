import CADCore
import Foundation
import Testing
@testable import LoftLineApp

/// A save is only a save once the file holds the project. SwiftUI hands the bytes to the system after
/// `snapshot` and `fileWrapper`, and says nothing about the write, so the document counts the project as saved
/// (and the recovery copy as no longer needed) when it finds the bytes of one of its saves in the file.
@MainActor
@Suite struct SaveConfirmationTests {
    func makeDoc() -> LoftLineDocument {
        LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
    }

    /// A dirty document with a recovery copy written for it.
    func dirtyDocument(file url: URL, store: RecoveryStore) -> (LoftLineDocument, RecoveryCoordinator) {
        let doc = makeDoc()
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)
        doc.perform("Rename") { $0.document.name = "Edited" }
        coordinator.tick()
        return (doc, coordinator)
    }

    /// What SwiftUI does for a save: take the snapshot, encode it. Returns the bytes the system is asked to write.
    func saveBytes(_ doc: LoftLineDocument) throws -> Data {
        try doc.fileData(for: doc.snapshot(contentType: .loftlineProject))
    }

    @Test func aSavedButUnwrittenSnapshotDoesNotMarkTheProjectSaved() throws {
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let (doc, coordinator) = dirtyDocument(file: AppTestSupport.tempDir().appendingPathComponent("a.loftline"), store: store)
        #expect(store.entries().count == 1)
        _ = try doc.snapshot(contentType: .loftlineProject)       // not even encoded yet
        coordinator.tick()
        #expect(doc.needsRecovery && store.entries().count == 1)
        _ = try saveBytes(doc)                                // encoded, never written
        coordinator.tick()
        #expect(doc.needsRecovery && store.entries().count == 1)
    }

    @Test func aFailedWriteKeepsTheDocumentDirtyAndItsRecoveryCopy() throws {
        let folder = AppTestSupport.tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let url = folder.appendingPathComponent("locked.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let (doc, coordinator) = dirtyDocument(file: url, store: store)

        let data = try saveBytes(doc)
        #expect(throws: (any Error).self) { try data.write(to: url) }   // the system's write fails
        #expect(!doc.confirmSave())
        #expect(doc.needsRecovery)
        coordinator.tick()
        #expect(store.entries().map(\.name) == ["Edited"])
    }

    @Test func aSuccessfulWriteClearsBothTheDirtyStateAndTheRecoveryCopy() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("ok.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let (doc, coordinator) = dirtyDocument(file: url, store: store)
        #expect(store.entries().count == 1)

        try saveBytes(doc).write(to: url)
        coordinator.tick()                       // the recovery timer is what looks at the file
        #expect(!doc.needsRecovery)
        #expect(store.entries().isEmpty)
        #expect(doc.confirmSave())               // the file still holds that save: the same answer
        #expect(!doc.needsRecovery)
    }

    @Test func aFileThatHoldsSomethingElseIsNotAConfirmation() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("other.loftline")
        let doc = makeDoc()
        doc.fileURL = url
        doc.perform("Rename") { $0.document.name = "Edited" }
        _ = try saveBytes(doc)
        try Data("the previous version".utf8).write(to: url)   // the write did not replace it
        #expect(!doc.confirmSave() && doc.needsRecovery)
        // Same size, different bytes: not confirmed either.
        let same = try saveBytes(doc)
        try Data(repeating: 0x20, count: same.count).write(to: url)
        #expect(!doc.confirmSave() && doc.needsRecovery)
        // And with no file at all, or a document that was never given a place.
        try FileManager.default.removeItem(at: url)
        #expect(!doc.confirmSave())
        doc.fileURL = nil
        #expect(!doc.confirmSave())
    }

    /// No time limit here: this suite runs on the main actor, so in a full run a limit also counts the wait for other
    /// main-actor tests (#130). That a pipe is never waited on is timed off the main actor, in `PipeReadTests`.
    @Test func aPipeInTheFilesPlaceIsNotWaitedOn() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("pipe.loftline")
        #expect(mkfifo(url.path, 0o644) == 0)
        let doc = makeDoc()
        doc.fileURL = url
        doc.perform("Rename") { $0.document.name = "Edited" }
        _ = try saveBytes(doc)
        #expect(!doc.confirmSave())              // returns at once instead of blocking on the open
        #expect(doc.needsRecovery)
    }

    @Test func editsMadeAfterTheSaveStayUnsaved() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("later.loftline")
        let doc = makeDoc()
        doc.fileURL = url
        doc.perform("First") { $0.document.name = "First" }
        try saveBytes(doc).write(to: url)
        doc.perform("Second") { $0.document.name = "Second" }
        #expect(doc.confirmSave())
        #expect(doc.lastSavedProject.document.name == "First")
        #expect(doc.needsRecovery)   // the second edit is not in the file
    }

    @Test func aLaterFailedSaveDoesNotUndoAnEarlierConfirmedOne() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("twice.loftline")
        let doc = makeDoc()
        doc.fileURL = url
        doc.perform("First") { $0.document.name = "First" }
        try saveBytes(doc).write(to: url)
        #expect(doc.confirmSave())
        doc.perform("Second") { $0.document.name = "Second" }
        _ = try saveBytes(doc)                 // handed over, never written
        #expect(doc.confirmSave())             // the file still holds the first save, and that stays the saved one
        #expect(doc.lastSavedProject.document.name == "First")
        #expect(doc.needsRecovery)
        try saveBytes(doc).write(to: url)      // saved again, and this one lands
        #expect(doc.confirmSave())
        #expect(!doc.needsRecovery)
    }

    /// Saves can overlap: the older one's bytes are encoded after the newer snapshot was taken. The bytes belong
    /// to the older save, so the file holding them says nothing about the newer project.
    @Test func bytesAreKeptAgainstTheSaveTheyWereEncodedFor() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("overlap.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let (doc, coordinator) = dirtyDocument(file: url, store: store)
        let older = try doc.snapshot(contentType: .loftlineProject)       // project "Edited"
        doc.perform("Again") { $0.document.name = "Again" }
        let newer = try doc.snapshot(contentType: .loftlineProject)       // project "Again"
        let olderBytes = try doc.fileData(for: older)                 // encoded last
        try olderBytes.write(to: url)                                 // and the newer write fails
        _ = newer

        #expect(doc.confirmSave())
        #expect(doc.lastSavedProject.document.name == "Edited")       // not "Again"
        #expect(doc.needsRecovery)
        coordinator.tick()
        #expect(store.entries().map(\.name) == ["Again"])             // the newer work keeps its copy
    }

    /// A save that reached the file but has not been looked at yet must survive a newer save that fails: the file
    /// holds the first one, so undoing back to the original is not "clean".
    @Test func anUnconfirmedSaveIsNotForgottenWhenANewerOneStarts() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("history.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        try saveBytes(doc).write(to: url)                              // A reaches the file, not yet looked at
        um.beginUndoGrouping(); doc.perform("B") { $0.document.name = "B" }; um.endUndoGrouping()
        _ = try saveBytes(doc)                                         // B fails
        um.undo(); um.undo()                                           // back to the original project
        #expect(doc.project.document.name != "A" && doc.project.document.name != "B")

        coordinator.tick()
        // The file holds A, the document holds the original: it is dirty and keeps its recovery copy.
        #expect(doc.lastSavedProject.document.name == "A")
        #expect(doc.needsRecovery)
        #expect(store.entries().count == 1)
    }

    /// A save that reached the file and was forgotten, because newer ones piled up before anyone looked, must not
    /// leave the document looking clean once the project is undone to the old baseline.
    @Test func forgettingAnUnlookedAtSaveNeverLeavesTheDocumentLookingClean() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("many.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)
        let original = doc.project.document.name

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        try saveBytes(doc).write(to: url)                              // A reaches the file, not yet looked at
        um.beginUndoGrouping(); doc.perform("B") { $0.document.name = "B" }; um.endUndoGrouping()
        for _ in 0..<9 { _ = try saveBytes(doc) }                      // nine saves that never land push A out
        um.undo(); um.undo()                                           // back to the original project
        #expect(doc.project.document.name == original)

        coordinator.tick()
        // The file holds A and the document holds the original: it must not be called clean.
        #expect(doc.needsRecovery)
        #expect(store.entries().count == 1)
        let copy = try #require(store.entries().first)
        #expect(try store.project(for: copy.id).document.name == original)

        // A later save that lands settles it again.
        try saveBytes(doc).write(to: url)
        coordinator.tick()
        #expect(!doc.needsRecovery)
        #expect(store.entries().isEmpty)
    }

    /// The file's content decides: an older save that lands after a newer one has replaced it.
    @Test func aLateOlderWriteMovesTheSavedProjectBack() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("late.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let (doc, coordinator) = dirtyDocument(file: url, store: store)
        let older = try doc.snapshot(contentType: .loftlineProject)       // project "Edited"
        doc.perform("Again") { $0.document.name = "Again" }
        let newer = try doc.snapshot(contentType: .loftlineProject)       // project "Again"
        let olderBytes = try doc.fileData(for: older)
        let newerBytes = try doc.fileData(for: newer)

        try newerBytes.write(to: url)
        coordinator.tick()
        #expect(!doc.needsRecovery)                                    // the newer save is the file
        try olderBytes.write(to: url)                                  // then the older one lands over it
        coordinator.tick()
        #expect(doc.lastSavedProject.document.name == "Edited")
        #expect(doc.needsRecovery)
        #expect(store.entries().map(\.name) == ["Again"])             // the newest work is protected again
    }

    /// A save forgotten by the list can still land later and replace a confirmed newer one. The file then holds
    /// something no known save explains, so the document must not be called clean (confirmation before eviction).
    @Test func aForgottenSaveLandingOverAConfirmedOneKeepsTheDocumentDirty() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("evicted-late.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        let a = try doc.snapshot(contentType: .loftlineProject)
        let aBytes = try doc.fileData(for: a)                          // encoded, its write delayed
        um.beginUndoGrouping(); doc.perform("B") { $0.document.name = "B" }; um.endUndoGrouping()
        try saveBytes(doc).write(to: url)
        coordinator.tick()                                             // B is the file and the saved project
        #expect(!doc.needsRecovery && doc.lastSavedProject.document.name == "B")

        um.beginUndoGrouping(); doc.perform("C") { $0.document.name = "C" }; um.endUndoGrouping()
        for _ in 0..<8 { _ = try saveBytes(doc) }                      // seven or more unwritten saves push A out
        coordinator.tick()
        um.undo()                                                      // C undone: the project is B again
        #expect(doc.project.document.name == "B")

        try aBytes.write(to: url)                                      // the delayed write lands over B
        coordinator.tick()
        #expect(doc.needsRecovery)                                     // the file holds A: not clean
        let copy = try #require(store.entries().first)
        #expect(try store.project(for: copy.id).document.name == "B")
    }

    /// The other order: uncertainty raised by a forgotten save is cleared by matching a newer retained save, and
    /// the forgotten one lands afterwards.
    @Test func aMatchAfterTheEvictionDoesNotLetTheForgottenSaveLandUnnoticed() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("evicted-then-match.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)

        doc.perform("A") { $0.document.name = "A" }
        let aBytes = try doc.fileData(for: doc.snapshot(contentType: .loftlineProject))   // A's write is delayed
        for i in 0..<8 {
            doc.perform("N\(i)") { $0.document.name = "N\(i)" }
            _ = try saveBytes(doc)                                     // eight more: A is forgotten
        }
        doc.perform("Last") { $0.document.name = "Last" }
        try saveBytes(doc).write(to: url)
        coordinator.tick()                                             // a retained save matches
        #expect(!doc.needsRecovery && doc.lastSavedProject.document.name == "Last")

        try aBytes.write(to: url)                                      // now the forgotten one lands
        coordinator.tick()
        #expect(doc.needsRecovery)
        #expect(store.entries().map(\.name) == ["Last"])
    }

    @Test func aSavedFileThatIsLaterRemovedOrReplacedIsNotCalledSaved() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("gone.loftline")
        let doc = makeDoc()
        doc.fileURL = url
        doc.perform("A") { $0.document.name = "A" }
        try saveBytes(doc).write(to: url)
        #expect(doc.confirmSave() && !doc.needsRecovery)
        try FileManager.default.removeItem(at: url)
        #expect(!doc.confirmSave())
        #expect(doc.needsRecovery)                                     // equal to the saved project, but not on disk
        // It is settled again when a save lands.
        try saveBytes(doc).write(to: url)
        #expect(doc.confirmSave() && !doc.needsRecovery)
        try Data("something else entirely".utf8).write(to: url)
        #expect(!doc.confirmSave() && doc.needsRecovery)
    }

    /// A snapshot can be forgotten by the list before it is encoded, and still produce bytes that land. With no
    /// save confirmed yet there is no remembered digest, so encoding it must itself raise the uncertainty.
    @Test func aSaveEncodedAfterTheListForgotItKeepsTheDocumentDirty() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("late-encode.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)
        let original = doc.project.document.name

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        let first = try doc.snapshot(contentType: .loftlineProject)        // taken, not encoded yet
        um.beginUndoGrouping(); doc.perform("B") { $0.document.name = "B" }; um.endUndoGrouping()
        for _ in 0..<8 { _ = try saveBytes(doc) }                      // eight more push the first one out
        coordinator.tick()                                             // a recovery copy of B
        let late = try doc.fileData(for: first)                        // now it is encoded, and written
        try late.write(to: url)
        um.undo(); um.undo()
        #expect(doc.project.document.name == original)

        coordinator.tick()
        #expect(doc.needsRecovery)                                     // the file holds A, the document the original
        let copy = try #require(store.entries().first)
        #expect(try store.project(for: copy.id).document.name == original)

        try saveBytes(doc).write(to: url)                              // an ordinary save settles it
        coordinator.tick()
        #expect(!doc.needsRecovery)
        #expect(store.entries().isEmpty)
    }

    /// Before any save is matched there is no remembered digest, but a file that none of the saves handed over
    /// explains (replaced, unreadable, gone) must still not let the document look clean.
    @Test func aFileNoSaveExplainsIsUnknownEvenBeforeTheFirstConfirmation() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("first.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)
        let original = doc.project.document.name

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        try saveBytes(doc).write(to: url)                              // A is written, not yet looked at
        um.undo()                                                      // the project is the original again
        try Data("replaced by someone else".utf8).write(to: url)       // and the file is replaced
        coordinator.tick()
        #expect(doc.needsRecovery)
        let copy = try #require(store.entries().first)
        #expect(try store.project(for: copy.id).document.name == original)
        // The same when the file cannot be read at all.
        try FileManager.default.removeItem(at: url)
        coordinator.tick()
        #expect(doc.needsRecovery)
        // An ordinary save settles it.
        try saveBytes(doc).write(to: url)
        coordinator.tick()
        #expect(!doc.needsRecovery)
    }

    /// One save id can be encoded twice with different bytes; either may land, and only the last is recorded.
    @Test func encodingOneSaveTwiceWithDifferentBytesKeepsTheDocumentDirty() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("twice-encoded.loftline")
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        let doc = makeDoc()
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        doc.fileURL = url
        let coordinator = RecoveryCoordinator(store: store)
        coordinator.register(doc)
        let original = doc.project.document.name

        um.beginUndoGrouping(); doc.perform("A") { $0.document.name = "A" }; um.endUndoGrouping()
        let snap = try doc.snapshot(contentType: .loftlineProject)
        let firstBytes = try doc.fileData(for: snap)
        var different = snap
        different.project.document.name = "A, encoded again"
        _ = try doc.fileData(for: different)                            // same save id, other bytes
        try firstBytes.write(to: url)                                   // the first payload is the one that lands
        um.undo()
        coordinator.tick()
        #expect(doc.needsRecovery)
        let copy = try #require(store.entries().first)
        #expect(try store.project(for: copy.id).document.name == original)
    }

    /// The identity check after the read (same device, inode, size and modification time) cannot be raced from a
    /// test; this pins that a stable file is read in full and digested the same way twice, and that two files
    /// of one size digest differently.
    @Test func aStableFileIsReadInFullAndDigestsTheSameTwice() throws {
        let size = 3 << 20
        let url = AppTestSupport.tempDir().appendingPathComponent("stable.loftline")
        try Data(repeating: 7, count: size).write(to: url)
        let a = try #require(LoftLineDocument.regularFileDigest(at: url, ofSizes: [size]))
        let b = try #require(LoftLineDocument.regularFileDigest(at: url, ofSizes: [size]))
        #expect(a.digest == b.digest && a.count == size)
        let other = AppTestSupport.tempDir().appendingPathComponent("other.loftline")
        try Data(repeating: 8, count: size).write(to: other)
        #expect(try #require(LoftLineDocument.regularFileDigest(at: other, ofSizes: [size])).digest != a.digest)
        #expect(LoftLineDocument.regularFileDigest(at: url, ofSizes: [size + 1]) == nil)   // other sizes are never read
    }
}

/// The file read under `confirmSave` never blocks on a pipe put in the file's place (`O_NONBLOCK`). Timed here, off the
/// main actor, so the limit measures only the read (#130).
@Suite struct PipeReadTests {
    @Test(.timeLimit(.minutes(1))) func aPipeIsRefusedAtOnce() {
        let url = AppTestSupport.tempDir().appendingPathComponent("pipe.loftline")
        #expect(mkfifo(url.path, 0o644) == 0)
        #expect(LoftLineDocument.regularFileDigest(at: url, ofSizes: [0, 10, 1000]) == nil)
    }
}
