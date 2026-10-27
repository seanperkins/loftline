import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct LayoutTiledExportTests {
    /// 110 x 24 in board (wider than the Avid's 60 in X travel): a pocket across the X = 55
    /// seam and a profile near the right end.
    func doc() -> LoftLineDocument {
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
        return doc
    }

    @Test func defaultTilesAreTheMachineTravel() {
        let s = TiledExport.defaultSettings(profile: BuiltInPosts.avidMach4Inch, units: .inch)
        #expect(s.tileWidth == 60 && s.tileHeight == 96)
        let mm = TiledExport.defaultSettings(profile: BuiltInPosts.avidMach4Inch, units: .millimeter)
        #expect(abs(mm.tileWidth - 1524) < 1e-9)
    }

    @Test func eachTileIsAValidProgramZeroedAtItsCorner() {
        let d = doc()
        let files = TiledExport.files(project: d.project, results: d.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96, overlap: 0.5))
        #expect(files.count == 2)
        #expect(files[0].fileName == "Bench_tile01.tap")
        #expect(files[1].title.contains("X54.75 Y0"))
        for f in files {
            #expect(f.result.text != nil)
            let errors = f.result.issues.filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(f.fileName): \(errors)")
        }
        // The pocket is split between both tiles; the profile is only in tile 2.
        #expect(files[0].tile.toolpaths.count == 1)
        #expect(files[1].tile.toolpaths.count == 2)
        #expect(files[1].result.text?.contains("tile 2 of 2") == true)
    }

    /// A keep-out zone in tile 2 is moved into the tile frame with the toolpaths, so a
    /// profile running through it is reported there (it is reported untiled too).
    @Test func keepOutZonesAreCheckedInTheirTilesFrame() {
        let d = doc()
        // Over the right profile's bottom edge (rect 90..100 x 8..14), clear of the pocket.
        var p = d.project
        p.document.keepOutZones = [KeepOutZone(name: "Clamp", outline: [Vec2(94, 7), Vec2(96, 7), Vec2(96, 9),
                                                                                   Vec2(94, 9)], height: 1)]
        let whole = GCodeExporter.export(project: p,
                                         toolpaths: GCodeExporter.toolpaths(scope: .all, operations: p.operations,
                                                                            results: d.results, groupByTool: false),
                                         profile: BuiltInPosts.avidMach4Inch, jobName: "Bench")
        #expect(whole.issues.contains { $0.severity == .error && $0.message.contains("Clamp") })
        let files = TiledExport.files(project: p, results: d.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 60, tileHeight: 96))
        #expect(files.count == 2)
        #expect(!files[0].result.issues.contains { $0.message.contains("Clamp") })
        #expect(files[1].result.issues.contains { $0.severity == .error && $0.message.contains("Clamp") },
                "\(files[1].result.issues)")
    }

    @Test func aJobThatFitsIsOneTile() {
        let d = doc()
        let files = TiledExport.files(project: d.project, results: d.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: TilingSettings(tileWidth: 120, tileHeight: 96))
        #expect(files.count == 1)
        #expect(files[0].tile.toolpaths.count == 2)
    }
}

/// Tiled export carries the same post, machine and tool notices as the other exports.
@Suite struct TiledExportNoticeTests {
    @Test func tileFilesCarryTheExtraIssuesFirst() throws {
        let d = LayoutTiledExportTests().doc()
        let settings = TilingSettings(tileWidth: 60, tileHeight: 96, overlap: 0.5)
        let plain = TiledExport.files(project: d.project, results: d.results, profile: BuiltInPosts.avidMach4Inch,
                                      groupByTool: false, settings: settings)
        let notice = GCodeIssue(severity: .warning, message: "This project posts with its own copy of a post.")
        let withNotice = TiledExport.files(project: d.project, results: d.results, profile: BuiltInPosts.avidMach4Inch,
                                           groupByTool: false, settings: settings, extraIssues: [notice])
        #expect(withNotice.count == plain.count && !withNotice.isEmpty)
        for (a, b) in zip(plain, withNotice) {
            #expect(b.result.issues.first == notice, "\(b.fileName)")
            #expect(Array(b.result.issues.dropFirst()) == a.result.issues, "nothing else changes")
            #expect(a.result.text == b.result.text)
        }
    }

    @Test func theSheetPassesTheDocumentsNotices() throws {
        // The sheet reads `document.postProfileIssues`: a project whose post is gone shows the error in every tile.
        var p = LoftLineProject(document: Document(name: "T", job: JobSetup(width: 110, height: 24, thickness: 0.75)),
                                postProfileID: "gone")
        let l = p.document.defaultLayerID
        p.document.add(AppTestSupport.rect(45, 8, 20, 6, layer: l))
        p.operations = [OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        let files = TilingSheet.tileFiles(document: doc, groupByTool: false,
                                          settings: TilingSettings(tileWidth: 60, tileHeight: 96, overlap: 0.5))
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { f in f.result.issues.contains { $0.severity == .error && $0.message.contains("gone") } })
    }
}
