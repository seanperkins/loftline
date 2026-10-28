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
        #expect(store.load().profiles.filter { $0.id.hasPrefix("shop") }.count == 1)
    }

    @Test func failedNewSaveLeavesNoFile() throws {
        let dir = folder()
        var store = PostProfileStore(directory: dir)
        store.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: (any Error).self) { try store.saveNew(shop()) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("shop.json").path))
    }
}
