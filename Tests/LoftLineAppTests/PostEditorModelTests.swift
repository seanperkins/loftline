import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The Post Processors sheet's model: Duplicate makes an unsaved draft, Save writes, Cancel discards, and the list is locked
/// while a draft has unsaved changes.
@Suite @MainActor struct PostEditorModelTests {
    func model() -> (PostEditorModel, URL, Box) {
        let dir = AppTestSupport.tempDir().appendingPathComponent("posts", isDirectory: true)
        var store = PostProfileStore(directory: dir)
        let trashed = Box()
        store.trash = { url in trashed.urls.append(url); try FileManager.default.removeItem(at: url) }
        return (PostEditorModel(catalog: PostProfileCatalog(store: store)), dir, trashed)
    }

    final class Box { var urls: [URL] = [] }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func duplicateIsAnUnsavedDraftWithTheBuiltInsController() {
        let (m, dir, _) = model()
        #expect(m.select(BuiltInPosts.avidMach4Inch.id))
        m.duplicate()
        #expect(m.isNew && m.isDirty)
        #expect(m.draft?.id == "avid-pro6096-mach4-inch-custom-1")
        #expect(m.draft?.controller == .mach4)
        #expect(files(dir).isEmpty, "Duplicate wrote a file")
    }

    @Test func saveWritesANewFileAndReloads() throws {
        let (m, dir, _) = model()
        _ = m.select(BuiltInPosts.genericGRBLMM.id)
        m.duplicate()
        m.draft?.name = "My GRBL"
        try m.save()
        #expect(files(dir) == ["generic-grbl-mm-custom-1.json"])
        #expect(!m.isDirty && !m.isNew)
        #expect(m.catalog.profiles.contains { $0.name == "My GRBL" })
    }

    @Test func saveIsRefusedWhileTheReportHasProblems() {
        let (m, dir, _) = model()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        m.duplicate()
        m.draft?.arcCW = "G3"
        #expect(!m.report.canSave)
        #expect(throws: (any Error).self) { try m.save() }
        #expect(files(dir).isEmpty)
    }

    @Test func listIsLockedWhileDirty() {
        let (m, _, _) = model()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        m.duplicate()
        #expect(!m.select(BuiltInPosts.genericGRBLMM.id))
        #expect(m.draft?.id == "avid-pro6096-mach4-inch-custom-1")
    }

    @Test func cancelDiscards() throws {
        let (m, _, _) = model()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        m.duplicate()
        m.cancel()
        #expect(!m.isDirty && m.draft == nil)
        _ = m.select(BuiltInPosts.genericGRBLMM.id)
        m.duplicate()
        try m.save()
        m.draft?.name = "Changed"
        m.cancel()
        #expect(m.draft?.name == "Generic GRBL (mm) (custom)" && !m.isDirty)
    }

    @Test func emptyPauseTextIsNil() {
        let (m, _, _) = model()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        m.duplicate()
        m.setLines(\PostProfile.preamble, "G90\n\nG17\n")
        #expect(m.draft?.preamble == ["G90", "G17"])
        m.setPauseText("  \n")
        #expect(m.draft?.pause == nil)
        m.setPauseText("M5\n{STOP}")
        #expect(m.draft?.pause == ["M5", "{STOP}"])
    }

    @Test func deleteTrashesACustomPost() throws {
        let (m, dir, trashed) = model()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        m.duplicate()
        try m.save()
        #expect(m.canDelete)
        try m.delete()
        #expect(trashed.urls.map(\.lastPathComponent) == ["avid-pro6096-mach4-inch-custom-1.json"])
        #expect(files(dir).isEmpty && m.draft == nil)
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        #expect(!m.canDelete)
    }

    /// A file with a built-in's id that did not load leaves the built-in read-only: saving must not replace the file someone
    /// may want to repair (or that a newer LoftLine wrote).
    @Test func aSkippedFileWithABuiltInsIDStaysReadOnly() throws {
        let (m, dir, _) = model()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: dir.appendingPathComponent("avid-pro6096-mach4-inch.json"))
        m.catalog.reload()
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        #expect(!m.isEditable && !m.canDelete)
        m.draft?.name = "Overwrite"
        #expect(throws: (any Error).self) { try m.save() }
        #expect(String(decoding: try Data(contentsOf: dir.appendingPathComponent("avid-pro6096-mach4-inch.json")), as: UTF8.self)
                == "{ broken")
    }
}
