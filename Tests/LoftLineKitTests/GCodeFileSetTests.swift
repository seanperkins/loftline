import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit

/// Save All and Save Tiled write a set of files as one: all of them or none, never over an
/// existing file without asking, and a failure part way through puts the folder back or says
/// exactly where the old files are.
@Suite struct GCodeFileSetTests {
    private struct Boom: Error {}

    private func file(_ name: String, _ title: String, _ text: String? = "G0 Z1\nM30\n") -> GCodeFileSet.File {
        GCodeFileSet.File(fileName: name, title: title, text: text)
    }

    /// Everything in `dir`, hidden items included.
    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func content(_ dir: URL, _ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    private func message(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return error.localizedDescription }
    }

    /// "dir", "staging" or "was", for telling the folders of a save apart in a fake.
    private func place(_ folder: GCodeFileSet.Folder) -> String {
        let name = folder.url.lastPathComponent
        return name.hasPrefix(GCodeFileSet.workingFolderPrefix) ? "staging" : name == GCodeFileSet.replacedFolderName ? "was" : "dir"
    }

    private func write(_ text: String, _ dir: URL, _ name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func aSetWithAFailedPostWritesNothingAndNamesTheFile() {
        let dir = AppTestSupport.tempDir()
        let set = GCodeFileSet(files: [file("tile_1.tap", "Tile 1"), file("tile_2.tap", "Tile 2", nil), file("tile_3.tap", "Tile 3")])
        #expect(set.unposted == ["Tile 2"])
        let m = message { try set.write(to: dir) }
        #expect(m.contains("Tile 2") && m.contains("Nothing was saved"))
        #expect(names(in: dir).isEmpty)
    }

    @Test func namesThatAreNotOnePlainFileEachAreRefused() {
        let dir = AppTestSupport.tempDir()
        for bad in ["", ".", "..", "was", "a/b.tap", "x/../../evil.tap", "nul\0.tap"] {
            let set = GCodeFileSet(files: [file(bad, "Bad"), file("ok.tap", "OK")])
            #expect(set.invalidNames == [bad], "\(bad.debugDescription)")
            #expect(throws: GCodeFileSetError.self) { try set.write(to: dir) }
        }
        // Two names the file system would fold into one (case, Unicode form) would make two programs one file.
        let twins = GCodeFileSet(files: [file("Caf\u{E9}.tap", "A"), file("Cafe\u{301}.tap", "B"), file("cafe\u{301}.tap", "C")])
        #expect(twins.invalidNames.count == 3)
        #expect(throws: GCodeFileSetError.self) { try twins.write(to: dir) }
        #expect(names(in: dir).isEmpty)
    }

    @Test func existingFilesAreReportedAndNotTouchedWithoutConfirmation() throws {
        let dir = AppTestSupport.tempDir()
        try write("old", dir, "b.tap")
        try write("keep", dir, "other.tap")
        let set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("c.tap", "C")])
        #expect(set.existing(in: dir) == ["b.tap"])
        #expect(set.needsReplaceConfirmation(in: dir))
        // Without the confirmed names the write refuses and the old file stands.
        let refused = message { try set.write(to: dir) }
        #expect(refused.contains("b.tap") && refused.contains("Nothing was saved"))
        #expect(try content(dir, "b.tap") == "old")
        #expect(names(in: dir) == ["b.tap", "other.tap"])
        // With them, the whole set lands, unrelated files stay, and the working folder is gone.
        let urls = try set.write(to: dir, replacing: ["b.tap"])
        #expect(urls.map(\.lastPathComponent) == ["a.tap", "b.tap", "c.tap"])
        #expect(names(in: dir) == ["a.tap", "b.tap", "c.tap", "other.tap"])
        #expect(try content(dir, "b.tap") == "G0 Z1\nM30\n")
        #expect(try content(dir, "other.tap") == "keep")
        #expect(!GCodeFileSet(files: [file("z.tap", "Z")]).needsReplaceConfirmation(in: dir))
    }

    @Test func aFailureBeforeAnythingMovedLeavesTheFolderAsItWas() throws {
        // Writing the third program into the working folder fails: nothing visible or hidden remains.
        let dir = AppTestSupport.tempDir()
        try write("old a", dir, "a.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("c.tap", "C")])
        let live = GCodeFileSet.FileOperations.live
        set.operations.writeText = { text, folder, name in
            try live.writeText(text, folder, name)
            if name == "c.tap" { throw Boom() }   // after the create: a write that failed part way
        }
        let m = message { try set.write(to: dir, replacing: ["a.tap"]) }
        #expect(m.contains("c.tap") && m.contains("as they were"))
        #expect(names(in: dir) == ["a.tap"])
        #expect(try content(dir, "a.tap") == "old a")
        // And when the working folder itself cannot be made.
        var noStage = set
        noStage.operations.makeFolder = { _, _ in throw Boom() }
        #expect(message { try noStage.write(to: dir, replacing: ["a.tap"]) }.contains("Nothing was saved"))
        #expect(names(in: dir) == ["a.tap"])
    }

    @Test func aFailurePartWayThroughPutsTheFolderBack() throws {
        // Two files already there; the third cannot be put in place after both were replaced. The old
        // files come back, the new ones go, and nothing hidden is left.
        let dir = AppTestSupport.tempDir()
        try write("old a", dir, "a.tap")
        try write("old b", dir, "b.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("c.tap", "C"), file("d.tap", "D")])
        let live = GCodeFileSet.FileOperations.live
        var moves: [String] = []
        set.operations.moveItem = { from, fromName, to, toName in
            if toName == "c.tap" { throw Boom() }
            try live.moveItem(from, fromName, to, toName)
            moves.append("\(place(from))/\(fromName)>\(place(to))/\(toName)")
        }
        let m = message { try set.write(to: dir, replacing: ["a.tap", "b.tap"]) }
        #expect(m.contains("c.tap") && m.contains("as they were"))
        // a aside, a in, b aside, b in; the new ones are removed (not moved), then b back, a back.
        #expect(moves == ["dir/a.tap>was/a.tap", "staging/a.tap>dir/a.tap", "dir/b.tap>was/b.tap", "staging/b.tap>dir/b.tap",
                          "was/b.tap>dir/b.tap", "was/a.tap>dir/a.tap"])
        #expect(names(in: dir) == ["a.tap", "b.tap"])
        #expect(try content(dir, "a.tap") == "old a")
        #expect(try content(dir, "b.tap") == "old b")
    }

    @Test func aFailureBetweenMovingAsideAndPuttingInPlaceRestoresThatFile() throws {
        // The old b has been renamed aside when the new b cannot go in: b must come back too, and a
        // dangling link at a name is renamed aside and back the same way.
        let dir = AppTestSupport.tempDir()
        try write("old a", dir, "a.tap")
        try write("old b", dir, "b.tap")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("l.tap"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        for failing in ["b.tap", "l.tap"] {
            var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("l.tap", "L")])
            let live = GCodeFileSet.FileOperations.live
            set.operations.moveItem = { from, fromName, to, toName in
                // The second rename only: the staged file (not the restore out of was/) onto its name.
                if toName == failing, place(from) == "staging" { throw Boom() }
                try live.moveItem(from, fromName, to, toName)
            }
            let m = message { try set.write(to: dir, replacing: ["a.tap", "b.tap", "l.tap"]) }
            #expect(m.contains(failing) && m.contains("as they were"), "\(failing): \(m)")
            #expect(names(in: dir) == ["a.tap", "b.tap", "l.tap"], "\(failing)")
            #expect(try content(dir, "a.tap") == "old a")
            #expect(try content(dir, "b.tap") == "old b")
            #expect(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("l.tap").path)[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    @Test func aFailedRestoreKeepsTheOldFilesAndSaysWhere() throws {
        // The third file cannot go in and the old b cannot come back: it must survive in the working
        // folder the error names, the new a must be gone, and the error must not claim the folder is as it was.
        let dir = AppTestSupport.tempDir()
        try write("old a", dir, "a.tap")
        try write("old b", dir, "b.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("c.tap", "C")])
        let live = GCodeFileSet.FileOperations.live
        set.operations.moveItem = { from, fromName, to, toName in
            if toName == "c.tap" { throw Boom() }
            if toName == "b.tap", place(from) == "was" { throw Boom() }   // the restore of b
            try live.moveItem(from, fromName, to, toName)
        }
        let m = message { try set.write(to: dir, replacing: ["a.tap", "b.tap"]) }
        #expect(!m.contains("as they were"))
        #expect(m.contains("Your earlier files are in") && m.contains(": b.tap.") && m.contains("/was"))
        let working = names(in: dir).filter { $0.hasPrefix(GCodeFileSet.workingFolderPrefix) }
        #expect(working.count == 1)
        #expect(try content(dir, "a.tap") == "old a")
        #expect(try content(dir, "\(working[0])/was/b.tap") == "old b")
        #expect(!names(in: dir).contains("c.tap"))
        #expect(m.contains(dir.appendingPathComponent(working[0]).appendingPathComponent("was").path))
    }

    @Test func aNewFileThatCannotBeRemovedIsNamedAsSuch() throws {
        let dir = AppTestSupport.tempDir()
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B")])
        let live = GCodeFileSet.FileOperations.live
        set.operations.moveItem = { from, fromName, to, toName in
            if toName == "b.tap" { throw Boom() }
            try live.moveItem(from, fromName, to, toName)
        }
        set.operations.removeItem = { folder, name in
            if name == "a.tap", place(folder) == "dir" { throw Boom() }
            try live.removeItem(folder, name)
        }
        let m = message { try set.write(to: dir) }
        #expect(m.contains("from this save") && m.contains("a.tap") && !m.contains("earlier"))
        #expect(names(in: dir) == ["a.tap"])   // the working folder goes: nothing of the user's is in it
    }

    @Test func aNewFileThatCannotBeRemovedKeepsItsOriginalAndSaysSo() throws {
        // The same double fault over a replaced file: the new a.tap cannot be removed, so the old one
        // cannot come back either. It must survive in was/ and the message must name both.
        let dir = AppTestSupport.tempDir()
        try write("old a", dir, "a.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B")])
        let live = GCodeFileSet.FileOperations.live
        set.operations.moveItem = { from, fromName, to, toName in
            if toName == "b.tap" { throw Boom() }
            try live.moveItem(from, fromName, to, toName)
        }
        set.operations.removeItem = { folder, name in
            if name == "a.tap", place(folder) == "dir" { throw Boom() }
            try live.removeItem(folder, name)
        }
        let m = message { try set.write(to: dir, replacing: ["a.tap"]) }
        #expect(m.contains("from this save, do not run as a set: a.tap.") && m.contains("Your earlier files are in"))
        let working = names(in: dir).filter { $0.hasPrefix(GCodeFileSet.workingFolderPrefix) }
        #expect(working.count == 1)
        #expect(try content(dir, "\(working[0])/was/a.tap") == "old a")
        #expect(try content(dir, "a.tap") == "G0 Z1\nM30\n")
    }

    @Test func aFileThatBecomesADirectoryDuringTheSaveIsPutBackAndRefused() throws {
        // b.tap is a file at the check and a folder by the time it is renamed aside: it must not be
        // deleted with the working folder.
        let dir = AppTestSupport.tempDir()
        try write("old b", dir, "b.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B")])
        let live = GCodeFileSet.FileOperations.live
        set.operations.writeText = { text, folder, name in
            try live.writeText(text, folder, name)
            if name == "a.tap" {
                try FileManager.default.removeItem(at: dir.appendingPathComponent("b.tap"))
                try FileManager.default.createDirectory(at: dir.appendingPathComponent("b.tap"), withIntermediateDirectories: false)
                try "inside".write(to: dir.appendingPathComponent("b.tap/x.txt"), atomically: true, encoding: .utf8)
            }
        }
        let m = message { try set.write(to: dir, replacing: ["b.tap"]) }
        #expect(m.contains("a folder, not a file, named b.tap") && m.contains("Nothing was saved"))
        #expect(names(in: dir) == ["b.tap"])
        #expect(try content(dir, "b.tap/x.txt") == "inside")
    }

    @Test func aFolderSwappedInForTheWorkingFolderIsNeitherUsedNorEmptied() throws {
        // Someone with write access to the folder moves the working folder away and puts the user's
        // own "Projects" folder, which holds a file with one of the set's names, at its name while
        // programs are being staged. The save holds the real working folder, so it finishes with its
        // own programs, and the swapped-in folder is neither written into nor emptied.
        let dir = AppTestSupport.tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Projects"), withIntermediateDirectories: false)
        try write("precious", dir, "Projects/notes.txt")
        try write("mine", dir, "Projects/b.tap")
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B")])
        let live = GCodeFileSet.FileOperations.live
        var swapped: URL?
        set.operations.writeText = { text, folder, name in
            try live.writeText(text, folder, name)
            if name == "a.tap" {
                try FileManager.default.moveItem(at: folder.url, to: dir.appendingPathComponent("elsewhere"))
                try FileManager.default.moveItem(at: dir.appendingPathComponent("Projects"), to: folder.url)
                swapped = folder.url
            }
        }
        try set.write(to: dir)
        #expect(try content(dir, "a.tap") == "G0 Z1\nM30\n")
        #expect(try content(dir, "b.tap") == "G0 Z1\nM30\n")
        let projects = try #require(swapped)
        #expect(try content(projects, "notes.txt") == "precious")
        #expect(try content(projects, "b.tap") == "mine")
        #expect(names(in: projects) == ["b.tap", "notes.txt"])
        // The real working folder, moved away, was cleaned out by name and is empty.
        #expect(names(in: dir.appendingPathComponent("elsewhere")).isEmpty)
        // An empty folder swapped in is not deleted either: the final rmdir checks identity first.
        let other = AppTestSupport.tempDir()
        var again = GCodeFileSet(files: [file("a.tap", "A")])
        var planted: URL?
        again.operations.writeText = { text, folder, name in
            try live.writeText(text, folder, name)
            try FileManager.default.moveItem(at: folder.url, to: other.appendingPathComponent("elsewhere"))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: false)
            planted = folder.url
        }
        try again.write(to: other)
        #expect(try content(other, "a.tap") == "G0 Z1\nM30\n")
        #expect(FileManager.default.fileExists(atPath: try #require(planted).path))
    }

    @Test func theLiveOperationsNeverWriteOverAnything() throws {
        // The exclusive create and exclusive rename the app uses: a file and a live link at the destination refuse, and nothing is
        // followed. On the Mac's file system, which folds case and Unicode form, so do a case twin and a Unicode-form twin; Linux's
        // keeps those apart as different files, so nothing is overwritten there either.
        let dir = AppTestSupport.tempDir()
        let live = GCodeFileSet.FileOperations.live
        let d = try live.openFolder(dir)
        try live.writeText("one", d, "a.tap")
        #expect(throws: (any Error).self) { try live.writeText("two", d, "a.tap") }
        #if canImport(Darwin)
        #expect(throws: (any Error).self) { try live.writeText("twin", d, "A.TAP") }
        #endif
        #expect(try content(dir, "a.tap") == "one")
        let elsewhere = AppTestSupport.tempDir()
        try write("pointed at", elsewhere, "real.tap")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("l.tap"), withDestinationURL: elsewhere.appendingPathComponent("real.tap"))
        #expect(throws: (any Error).self) { try live.writeText("through", d, "l.tap") }
        #expect(try content(elsewhere, "real.tap") == "pointed at")
        try live.writeText("new", d, "n.tap")
        try live.writeText("nfc", d, "Caf\u{E9}.tap")
        #if canImport(Darwin)
        let taken = ["a.tap", "A.TAP", "l.tap", "Cafe\u{301}.tap"]
        #else
        let taken = ["a.tap", "l.tap"]
        #endif
        for taken in taken {
            #expect(throws: (any Error).self) { try live.moveItem(d, "n.tap", d, taken) }
        }
        #expect(try content(dir, "n.tap") == "new")
        #expect(try content(dir, "a.tap") == "one")
        #expect(try content(elsewhere, "real.tap") == "pointed at")
        try live.moveItem(d, "n.tap", d, "m.tap")
        #expect(try content(dir, "m.tap") == "new")
        // A link where a folder is to be made is refused, not followed; a folder is removed only empty.
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("work"), withDestinationURL: elsewhere)
        #expect(throws: (any Error).self) { try live.makeFolder(d, "work") }
        #expect(names(in: elsewhere) == ["real.tap"])
        let sub = try live.makeFolder(d, "sub")
        try live.writeText("x", sub, "x.tap")
        #expect(throws: (any Error).self) { try live.removeItem(d, "sub") }
        #expect(try content(dir, "sub/x.tap") == "x")
        // A set written through a link to the folder lands in the folder.
        let alias = AppTestSupport.tempDir().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        try GCodeFileSet(files: [file("z.tap", "Z")]).write(to: alias)
        #expect(try content(dir, "z.tap") == "G0 Z1\nM30\n")
    }

    @Test func aFileThatAppearsLateStopsTheSave() throws {
        let dir = AppTestSupport.tempDir()
        var set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B")])
        #expect(!set.needsReplaceConfirmation(in: dir))
        // After the question, before the write: refused outright.
        try write("late", dir, "b.tap")
        let m = message { try set.write(to: dir, replacing: []) }
        #expect(m.contains("b.tap") && m.contains("Nothing was saved"))
        #expect(try content(dir, "b.tap") == "late")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.tap"))
        // During the write (a sync client drops it in while programs are being staged): the exclusive
        // rename refuses it, so the save fails and rolls back with the late file untouched.
        let live = GCodeFileSet.FileOperations.live
        set.operations.writeText = { text, folder, name in
            try live.writeText(text, folder, name)
            if name == "a.tap" { try "late".write(to: dir.appendingPathComponent("b.tap"), atomically: true, encoding: .utf8) }
        }
        let m2 = message { try set.write(to: dir, replacing: []) }
        #expect(m2.contains("b.tap") && m2.contains("as they were"))
        #expect(names(in: dir) == ["b.tap"])
        #expect(try content(dir, "b.tap") == "late")
    }

    @Test func aDirectoryIsNeverReplacedAndALinkIsReplacedAsALink() throws {
        let dir = AppTestSupport.tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("a.tap"), withIntermediateDirectories: false)
        try write("inside", dir, "a.tap/x.txt")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("b.tap"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        let elsewhere = AppTestSupport.tempDir()
        try write("pointed at", elsewhere, "real.tap")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("c.tap"), withDestinationURL: elsewhere.appendingPathComponent("real.tap"))
        let set = GCodeFileSet(files: [file("a.tap", "A"), file("b.tap", "B"), file("c.tap", "C")])
        // A directory stops the save before anything changes; links, dangling or live, are asked about.
        #expect(set.existing(in: dir) == ["b.tap", "c.tap"])
        #expect(set.links(in: dir) == ["b.tap", "c.tap"])
        let m = message { try set.write(to: dir, replacing: ["b.tap", "c.tap"]) }
        #expect(m.contains("a.tap") && m.contains("Nothing was saved"))
        #expect(try content(dir, "a.tap/x.txt") == "inside")
        let links = GCodeFileSet(files: [file("b.tap", "B"), file("c.tap", "C")])
        // Confirmed links are replaced by files; what a live link pointed to is untouched.
        try links.write(to: dir, replacing: ["b.tap", "c.tap"])
        #expect(try content(dir, "b.tap") == "G0 Z1\nM30\n")
        #expect(try content(dir, "c.tap") == "G0 Z1\nM30\n")
        #expect(try fm.attributesOfItem(atPath: dir.appendingPathComponent("c.tap").path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try content(elsewhere, "real.tap") == "pointed at")
        #expect(names(in: dir) == ["a.tap", "b.tap", "c.tap"])
    }

    @Test func fileNamesAreOnePlainVisibleNameEach() {
        var profile = BuiltInPosts.avidMach4Inch
        profile.fileExtension = "x/../../evil"
        let name = GCodeExporter.suggestedFileName(jobName: ".", operationName: nil, profile: profile)
        #expect(!name.contains("/") && !name.hasPrefix("."))
        profile.fileExtension = ""
        #expect(GCodeExporter.suggestedFileName(jobName: ".hidden", operationName: "Op", profile: profile) == "_hidden_Op.tap")
    }
}
