import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Sharing a post: one empty-pause rule on every read path, new saves that never overwrite or leave a partial file, importing a
/// post file as a draft, and adding the post a project carries.
@Suite @MainActor struct PostShareTests {
    func folder() -> URL {
        let dir = AppTestSupport.tempDir().appendingPathComponent("posts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func shop(_ id: String = "shop") -> PostProfile {
        var p = BuiltInPosts.avidMach4Inch
        p.id = id
        p.name = "Shop post"
        p.footer.append("(shop)")
        return p
    }

    // MARK: Task 1

    @Test func normalizedReadsEmptyPauseAsNil() {
        var p = shop()
        p.pause = []
        #expect(p.normalized.pause == nil)
        p.pause = ["M5", "{STOP}"]
        #expect(p.normalized.pause == ["M5", "{STOP}"])
    }

    @Test func carriedEmptyPauseStops() throws {
        var carried = shop()
        carried.pause = []
        var project = LoftLineProject(document: Document(name: "T", units: .inch), postProfileID: carried.id)
        project.postSnapshot = try carried.snapshot()
        let copy = try #require(ProjectPost.postCopy(of: project))
        #expect(copy.pause == nil && copy.pauseLines.contains("{STOP}"))
        // Installed as Add saves it: the project resolves it equal, with no copy-differs warning.
        let r = ProjectPost.resolve(project, profiles: BuiltInPosts.all + [carried.normalized], machines: [])
        #expect(r.postSource == .projectCopy && r.postCopyDiffers == nil)
    }

    @Test func keepingIDRefusesAnExistingFile() throws {
        let store = PostProfileStore(directory: folder())
        _ = try store.saveNew(shop())
        #expect(throws: (any Error).self) { try store.saveNew(shop(), keepingID: true) }
        // The built-in ShopBot post shares the prefix: count the saved files only.
        #expect(store.load().profiles.filter { $0.id.hasPrefix("shop") && BuiltInPosts.profile(id: $0.id) == nil }.count == 1)
    }

    @Test func failedNewSaveLeavesNoFile() throws {
        let dir = folder()
        var store = PostProfileStore(directory: dir)
        store.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try store.saveNew(shop()) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("shop.json").path))
    }

    // MARK: Task 2

    func model(_ dir: URL) -> PostEditorModel {
        PostEditorModel(catalog: PostProfileCatalog(store: PostProfileStore(directory: dir)))
    }

    @Test func importIDKeepsAFreeIDAndRenamesTakenOnes() throws {
        let dir = folder()
        let store = PostProfileStore(directory: dir)
        #expect(store.importID(for: "fresh") == "fresh")
        #expect(store.importID(for: BuiltInPosts.avidMach4Inch.id) == "avid-pro6096-mach4-inch-custom-1")
        _ = try store.saveNew(shop())
        #expect(store.importID(for: "shop") == "shop-custom-1")
        #expect(store.importID(for: "SHOP") == "SHOP-custom-1")
        try Data("{".utf8).write(to: dir.appendingPathComponent("broken.json"))
        #expect(store.importID(for: "broken") == "broken-custom-1")
        #expect(store.importID(for: "../x") == "imported-post")
    }

    @Test func importDraftIsUnsavedAndChecked() {
        let dir = folder()
        let m = model(dir)
        m.beginImport(shop("from-a-friend"))
        #expect(m.isNew && m.isDirty && m.draft?.id == "from-a-friend" && m.draft?.name == "Shop post")
        #expect(m.report.canSave)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
    }

    @Test func importedBuiltInKeepsItsController() {
        let m = model(folder())
        m.beginImport(BuiltInPosts.avidMach4Inch)
        #expect(m.draft?.id == "avid-pro6096-mach4-inch-custom-1" && m.draft?.controller == .mach4)
        #expect(m.report.probeProgram != nil)
        var empty = shop("quiet")
        empty.pause = []
        m.cancel()
        m.beginImport(empty)
        #expect(m.draft?.pause == nil)
    }

    @Test func importedProbeKeyIsDropped() throws {
        var json = try JSONSerialization.jsonObject(with: shop("probed").toJSON()) as! [String: Any]
        json["toolChangeProbe"] = ["on": ["_0": ["parkX": 1]]]
        let dir = folder()
        let url = dir.deletingLastPathComponent().appendingPathComponent("probed.loftlinepost")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let read = try PostProfileStore(directory: dir).read(url)
        #expect(read.toolChangeProbe == nil)
    }

    @Test func readRefusesABigFileBeforeReading() throws {
        let url = folder().deletingLastPathComponent().appendingPathComponent("big.loftlinepost")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 2 * 1024 * 1024)   // sparse: nothing written
        try h.close()
        #expect(throws: (any Error).self) { try PostProfileStore(directory: folder()).read(url) }
        let bad = url.deletingLastPathComponent().appendingPathComponent("bad.loftlinepost")
        try Data("{ nope".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try PostProfileStore(directory: folder()).read(bad) }
    }

    @Test func addStateCases() throws {
        let dir = folder()
        let m = model(dir)
        #expect(m.addState(for: nil) == .hidden)
        #expect(m.addState(for: shop("free")) == .enabled)
        var unsafe = shop()
        unsafe.id = "../x"
        guard case .disabled(let r1) = m.addState(for: unsafe) else { Issue.record("unsafe id enabled"); return }
        #expect(r1.contains("plain file name"))
        try Data("{".utf8).write(to: dir.appendingPathComponent("taken.json"))
        guard case .disabled(let r2) = m.addState(for: shop("taken")) else { Issue.record("taken id enabled"); return }
        #expect(r2.contains("taken"))
        m.beginImport(shop("other"))
        guard case .disabled = m.addState(for: shop("free")) else { Issue.record("enabled while dirty"); return }
    }

    @Test func carriedPostIsTheRawCopyAndAddInstallsIt() throws {
        let dir = folder()
        var carried = shop("their-post")
        carried.limits.xTravel = 10   // differs from the Avid machine's 60 in
        var project = LoftLineProject(document: Document(name: "T", units: .inch), postProfileID: carried.id,
                                      machineID: BuiltInMachines.avidPRO6096.id)
        project.postSnapshot = try carried.snapshot()
        project.machineSnapshot = try BuiltInMachines.avidPRO6096.snapshot()
        let doc = LoftLineDocument(project: project, toolLibrary: AppTestSupport.library())
        let raw = try #require(doc.carriedPostNotInstalled)
        #expect(raw.limits.xTravel == 10)
        let m = model(dir)
        m.beginAdd(raw)   // a draft, as Import is; Save writes it with the id kept
        try m.save()
        let installed = m.catalog.profiles.first { $0.id == "their-post" }
        #expect(installed?.limits.xTravel == 10)
        let r = ProjectPost.resolve(project, profiles: m.catalog.profiles, machines: [BuiltInMachines.avidPRO6096])
        #expect(r.postInstalledHere && r.postCopyDiffers == nil)
    }

    // MARK: Task 3

    @Test func exportWritesTheSavedPostsBytes() throws {
        let m = model(folder())
        _ = m.select(BuiltInPosts.avidMach4Inch.id)
        #expect(m.exportData() == nil)   // a built-in is on every Mac: Duplicate it to share a copy
        m.duplicate()
        #expect(m.exportData() == nil)   // unsaved
        try m.save()
        let data = try #require(m.exportData())
        #expect(try PostProfile.fromJSON(data) == m.draft)
    }
}
