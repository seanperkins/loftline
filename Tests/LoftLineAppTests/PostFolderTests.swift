import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// The posts folder: what loads, what is listed as not loaded and why, and how files are named, saved and removed.
@Suite struct PostFolderTests {
    func store() -> (PostProfileStore, URL) {
        let dir = AppTestSupport.tempDir().appendingPathComponent("posts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PostProfileStore(directory: dir), dir)
    }

    func custom(_ id: String) -> PostProfile {
        var p = BuiltInPosts.avidMach4Inch
        p.id = id
        p.name = "Shop post"
        return p
    }

    func write(_ p: PostProfile, as name: String, in dir: URL) throws {
        try p.toJSON().write(to: dir.appendingPathComponent(name))
    }

    @Test func aGoodFileLoads() throws {
        let (s, dir) = store()
        try write(custom("shop"), as: "shop.json", in: dir)
        let r = s.load()
        #expect(r.profiles.contains { $0.id == "shop" } && r.skipped.isEmpty)
    }

    @Test func malformedAndNewerFilesAreSkipped() throws {
        let (s, dir) = store()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        var json = try JSONSerialization.jsonObject(with: custom("newer").toJSON()) as! [String: Any]
        json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("newer.json"))
        let r = s.load()
        #expect(Set(r.skipped.map(\.fileName)) == ["broken.json", "newer.json"])
        #expect(r.skipped.allSatisfy { !$0.reason.isEmpty })
        #expect(r.skipped.first { $0.fileName == "newer.json" }?.reason.contains("newer") == true)
    }

    @Test func unsafeIDIsSkipped() throws {
        let (s, dir) = store()
        try write(custom("../x"), as: "x.json", in: dir)
        #expect(s.load().skipped.map(\.fileName) == ["x.json"])
    }

    @Test func misnamedFileIsSkippedWithItsReason() throws {
        let (s, dir) = store()
        try write(custom("avid-x"), as: "Avid.json", in: dir)
        try write(custom("shop"), as: "Shop.json", in: dir)   // case only
        let r = s.load()
        #expect(Set(r.skipped.map(\.fileName)) == ["Avid.json", "Shop.json"])
        #expect(r.skipped.allSatisfy { $0.reason.contains(".json") })
        #expect(!r.profiles.contains { $0.id == "avid-x" || $0.id == "shop" })
    }

    @Test func finderCopyDoesNotHideTheOriginal() throws {
        let (s, dir) = store()
        try write(custom("x"), as: "x copy.json", in: dir)
        try write(custom("x"), as: "x.json", in: dir)
        let r = s.load()
        #expect(r.profiles.filter { $0.id == "x" }.count == 1)
        #expect(r.skipped.map(\.fileName) == ["x copy.json"])
    }

    @Test func emptyPauseLoadsAsNil() throws {
        let (s, dir) = store()
        var p = custom("quiet")
        p.pause = []
        try write(p, as: "quiet.json", in: dir)
        #expect(s.load().profiles.first { $0.id == "quiet" }?.pause == nil)
    }

    @Test func newIDAvoidsSkippedAndCaseClashes() throws {
        let (s, dir) = store()
        try Data("{".utf8).write(to: dir.appendingPathComponent("avid-pro6096-mach4-inch-custom-1.json"))   // skipped
        try write(custom("avid-pro6096-mach4-inch-custom-2"), as: "AVID-PRO6096-MACH4-INCH-CUSTOM-2.json", in: dir)
        #expect(s.newID(from: "avid-pro6096-mach4-inch") == "avid-pro6096-mach4-inch-custom-3")
        #expect(s.newID(from: "shop-custom-1") == "shop-custom-1")
        try write(custom("shop-custom-1"), as: "shop-custom-1.json", in: dir)
        #expect(s.newID(from: "shop-custom-1") == "shop-custom-2")
        #expect(PostProfileStore.isSafeID("a.b_c-1") && !PostProfileStore.isSafeID("../x") && !PostProfileStore.isSafeID(".hidden")
                && !PostProfileStore.isSafeID("") && !PostProfileStore.isSafeID("a/b"))
    }

    @Test func exclusiveCreateTakesTheNextID() throws {
        let (s, _) = store()
        let first = try s.saveNew(custom("shop-custom-1"))
        let second = try s.saveNew(custom("shop-custom-1"))   // another window had the same id
        #expect(first.id == "shop-custom-1" && second.id == "shop-custom-2")
        #expect(s.load().profiles.filter { $0.id.hasPrefix("shop-custom-") }.count == 2)
    }

    @Test func saveRefusesUnsafeID() {
        let (s, _) = store()
        #expect(throws: (any Error).self) { try s.save(custom("../x")) }
        #expect(throws: (any Error).self) { try s.saveNew(custom("a/b")) }
    }

    @Test func saveReplacesItsOwnFile() throws {
        let (s, _) = store()
        var p = try s.saveNew(custom("shop"))
        p.name = "Renamed"
        try s.save(p)
        #expect(s.load().profiles.first { $0.id == "shop" }?.name == "Renamed")
    }

    @Test func deleteCallsTheInjectedTrash() throws {
        var (s, dir) = store()
        var trashed: [URL] = []
        s.trash = { url in trashed.append(url); try FileManager.default.removeItem(at: url) }
        _ = try s.saveNew(custom("shop"))
        #expect(s.isUserPost("shop"))
        try s.delete(id: "shop")
        #expect(trashed.map(\.lastPathComponent) == ["shop.json"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("shop.json").path))
        #expect(!s.isUserPost("shop"))
    }

    @Test func cliMessagesForSkippedFiles() {
        let lines = LoftLineCLI.skippedMessages([SkippedPost(fileName: "a.json", reason: "malformed")])
        #expect(lines == ["warning: post file a.json did not load: malformed\n"])
    }
}
