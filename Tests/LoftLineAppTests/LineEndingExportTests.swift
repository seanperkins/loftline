import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Each program file gets its post's line endings; the program text stays LF (#99 item 4). Checked on UTF-8 bytes.
@Suite struct LineEndingExportTests {
    static let cr: UInt8 = 13

    static func export(_ profile: PostProfile, project: LoftLineProject = AppTestSupport.project()) throws -> GCodeExportResult {
        let ids = project.document.shapes.map(\.id)
        let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: ToolLibrary.seeded.tools[0].id,
                                                                             shapeIDs: ids)))
        let tps = try op.generate(in: CAMContext(document: project.document, tools: .seeded))
        return GCodeExporter.export(project: project, toolpaths: tps, profile: profile, jobName: "T", expected: .notChecked(because: "test"))
    }

    @Test func massoFilesAreCRLFAndItsTextIsNot() throws {
        let r = try Self.export(BuiltInPosts.massoG3Inch)
        let text = try #require(r.text)
        #expect(!Array(text.utf8).contains(Self.cr))
        let file = try #require(r.fileText)
        #expect(Array(file.utf8) == Array(PostProfile.LineEnding.crlf.apply(text).utf8))
        #expect(Array(file.utf8).contains(Self.cr))
        let avid = try Self.export(BuiltInPosts.avidMach4Inch)
        #expect(avid.fileText.map { Array($0.utf8) } == avid.text.map { Array($0.utf8) })
    }

    @Test func saveAllWritesTheFileText() throws {
        let r = try Self.export(BuiltInPosts.massoG3Inch)
        let set = GCodeFileSet(posted: [(file: PlannedGCodeFile(fileName: "a.nc", title: "A", toolpaths: []), result: r)])
        let dir = AppTestSupport.tempDir()
        let urls = try set.write(to: dir)
        let bytes = try Data(contentsOf: try #require(urls.first))
        #expect(Array(bytes) == Array(try #require(r.fileText).utf8))
    }

    /// Tiled export writes each tile with the post's line endings.
    @Test func tiledMassoFilesAreCRLF() throws {
        var d = Document(name: "Bench", job: JobSetup(width: 110, height: 24, thickness: 0.75))
        d.add(AppTestSupport.rect(45, 8, 20, 6, layer: d.defaultLayerID))
        var p = LoftLineProject(document: d)
        p.operations = [OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [d.shapes[0].id])!]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        let tiles = TiledExport.files(project: doc.project, results: doc.results, profile: BuiltInPosts.massoG3Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96))
        #expect(tiles.count >= 2)
        let dir = AppTestSupport.tempDir()
        let urls = try GCodeFileSet(tiles: tiles).write(to: dir)
        #expect(urls.count == tiles.count)
        for url in urls {
            let bytes = Array(try Data(contentsOf: url))
            let lf = bytes.indices.filter { bytes[$0] == 10 }
            #expect(!lf.isEmpty, "\(url.lastPathComponent)")
            #expect(lf.allSatisfy { $0 > 0 && bytes[$0 - 1] == Self.cr }, "\(url.lastPathComponent)")
        }
    }

    /// The project's own copy posts (the copy wins): an old MASSO copy (LF, 1.0) keeps writing LF and is reported as
    /// differing from the installed post.
    @Test func anOldMassoCopyStaysLFAndIsReported() throws {
        var old = BuiltInPosts.massoG3Inch
        old.lineEnding = nil; old.version = "1.0"
        var p = AppTestSupport.project()
        p.postProfileID = old.id
        p.postSnapshot = try old.snapshot()
        let r = ProjectPost.resolve(p, profiles: BuiltInPosts.all, machines: [])
        #expect(r.postSource == .projectCopy)
        #expect(r.postCopyDiffers != nil)
        let out = try Self.export(r.post, project: p)
        #expect(!Array(try #require(out.fileText).utf8).contains(Self.cr))
    }

    @Test func aCRLFProgramReadsLikeItsLFForm() throws {
        let text = try #require(try Self.export(BuiltInPosts.massoG3Inch).text)
        let crlf = PostProfile.LineEnding.crlf.apply(text)
        let a = GCodeReader.read(text, units: .inch, startZ: 1), b = GCodeReader.read(crlf, units: .inch, startZ: 1)
        #expect(a.segments.map(\.moves) == b.segments.map(\.moves))
        #expect(!a.segments.isEmpty)
    }
}
