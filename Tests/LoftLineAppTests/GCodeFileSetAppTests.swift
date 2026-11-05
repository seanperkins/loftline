import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The parts of Save All and Save Tiled that need the app: the replace alert's text and a document's tiles. The set itself is tested in
/// LoftLineKitTests, where it also runs on Linux.
@Suite struct GCodeFileSetAppTests {
    private func file(_ name: String, _ title: String, _ text: String? = "G0 Z1\nM30\n") -> GCodeFileSet.File {
        GCodeFileSet.File(fileName: name, title: title, text: text)
    }

    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func write(_ text: String, _ dir: URL, _ name: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test func theAlertSaysWhichNamesAreLinks() throws {
        let dir = AppTestSupport.tempDir()
        let fm = FileManager.default
        try fm.createSymbolicLink(at: dir.appendingPathComponent("b.tap"), withDestinationURL: dir.appendingPathComponent("nowhere"))
        let elsewhere = AppTestSupport.tempDir()
        try write("pointed at", elsewhere, "real.tap")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("c.tap"), withDestinationURL: elsewhere.appendingPathComponent("real.tap"))
        let links = GCodeFileSet(files: [file("b.tap", "B"), file("c.tap", "C")])
        let both = ReplaceRequest(set: links, directory: dir)
        #expect(both.links == ["b.tap", "c.tap"] && both.summary.contains("2 of them are links"))
        let one = ReplaceRequest(set: GCodeFileSet(files: [file("c.tap", "C")]), directory: dir)
        #expect(one.summary.contains("c.tap is a link") && one.summary.contains("left as it is"))
        try links.write(to: dir, replacing: ["b.tap", "c.tap"])
        #expect(ReplaceRequest(set: links, directory: dir).links.isEmpty)   // they are files now
    }

    @Test func theReplaceRequestSummarisesTheNames() throws {
        let dir = AppTestSupport.tempDir()
        for n in 1...7 { try write("x", dir, "f\(n).tap") }
        let five = ReplaceRequest(set: GCodeFileSet(files: (1...5).map { file("f\($0).tap", "F\($0)") }), directory: dir)
        #expect(five.names.count == 5 && !five.summary.contains("more"))
        let six = ReplaceRequest(set: GCodeFileSet(files: (1...6).map { file("f\($0).tap", "F\($0)") }), directory: dir)
        #expect(six.summary.contains("and 1 more") && six.summary.contains("them"))
        let one = ReplaceRequest(set: GCodeFileSet(files: [file("f7.tap", "F7"), file("new.tap", "N")]), directory: dir)
        #expect(one.names == ["f7.tap"] && one.summary.contains("over it"))
    }

    @Test func tiledSetsComeFromTheTiles() throws {
        // A 110 x 24 in board split into 60 in tiles: a pocket across the seam and a profile at the end.
        var d = Document(name: "Bench", job: JobSetup(width: 110, height: 24, thickness: 0.75))
        let l = d.defaultLayerID
        d.add(AppTestSupport.rect(45, 8, 20, 6, layer: l))
        d.add(AppTestSupport.rect(90, 8, 10, 6, layer: l))
        var p = LoftLineProject(document: d)
        p.operations = [
            OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [d.shapes[0].id])!,
            OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [d.shapes[1].id])!,
        ]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        var tiles = TiledExport.files(project: doc.project, results: doc.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96))
        #expect(tiles.count >= 2)
        let good = GCodeFileSet(tiles: tiles)
        #expect(good.unposted.isEmpty && good.invalidNames.isEmpty)
        let dir = AppTestSupport.tempDir()
        #expect(try good.write(to: dir).count == tiles.count)
        #expect(names(in: dir).count == tiles.count)   // no working folder left behind
        // One tile that failed to post keeps the whole set out of the folder.
        tiles[1].result.text = nil
        tiles[1].result.errorMessage = "post failed"
        let broken = GCodeFileSet(tiles: tiles)
        let other = AppTestSupport.tempDir()
        #expect(throws: GCodeFileSetError.self) { try broken.write(to: other) }
        #expect(names(in: other).isEmpty)
        #expect(broken.unposted == [tiles[1].title])
        // A post profile's extension is user JSON: it is cleaned for tiles as for Save All.
        var hostile = BuiltInPosts.avidMach4Inch
        hostile.fileExtension = "x/../../evil"
        let tileNames = TiledExport.files(project: doc.project, results: doc.results, profile: hostile,
                                          groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96)).map(\.fileName)
        #expect(!tileNames.isEmpty && tileNames.allSatisfy { !$0.contains("/") && $0.hasSuffix(".xevil") })
    }
}
