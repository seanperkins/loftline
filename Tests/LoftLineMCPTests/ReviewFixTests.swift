import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// Findings of the branch review (debate 86da8cce), each pinned before its fix.
@Suite struct ReviewFixTests {
    static func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-fix-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A: a running server follows the folder list as the user changes it.
    @Test func theAllowedFoldersAreReadAgainOnEveryCall() throws {
        let root = Self.dir()
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let file = root.appendingPathComponent("assistant.json")
        try AssistantSettings(allowedFolders: [a.path]).save(to: file)
        let access = AssistantAccess(settingsFile: file)
        _ = try access.resolve(a.appendingPathComponent("x.tap").path)
        #expect(throws: AssistantAccessError.self) { try access.resolve(b.appendingPathComponent("x.tap").path) }
        try AssistantSettings(allowedFolders: [b.path]).save(to: file)
        _ = try access.resolve(b.appendingPathComponent("x.tap").path)
        #expect(throws: AssistantAccessError.self) { try access.resolve(a.appendingPathComponent("x.tap").path) }
    }

    /// B: on a case-sensitive volume, Jobs and jobs are different folders.
    @Test func caseMattersOnACaseSensitiveVolume() {
        let root = URL(fileURLWithPath: "/Volumes/Work/Jobs")
        #expect(AssistantAccess.isInside(URL(fileURLWithPath: "/Volumes/Work/Jobs/a.tap"), root: root, caseSensitive: true))
        #expect(!AssistantAccess.isInside(URL(fileURLWithPath: "/Volumes/Work/jobs/a.tap"), root: root, caseSensitive: true))
        #expect(AssistantAccess.isInside(URL(fileURLWithPath: "/Volumes/Work/jobs/a.tap"), root: root, caseSensitive: false))
        #expect(!AssistantAccess.isInside(URL(fileURLWithPath: "/Volumes/Work/Jobs2/a.tap"), root: root, caseSensitive: false))
    }

    /// C: one toolpath posted alone gets a sheet and a summary for that toolpath, with its own side's setup.
    @Test func aSingleToolpathPostDescribesThatToolpath() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        var bottomID = UUID()
        h.session.perform("Two-sided") { p in
            var form = JobSetupForm(document: p.document)
            form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
            p = form.apply(to: p)
            let bottomLayer = p.document.layers.first { $0.side == .bottom }!.id
            p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 2, height: 1))]))
            p.document.add(Shape(layerID: bottomLayer, paths: [ShapeFactory.rectangle(Rect2(x: 5, y: 1, width: 2, height: 1))]))
            var top = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[0].id])!
            var setup = top.editableSetup
            setup.name = "Top profile"
            top.editableSetup = setup
            var bottom = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[1].id])!
            setup = bottom.editableSetup
            setup.name = "Bottom profile"
            bottom.editableSetup = setup
            bottomID = bottom.id
            p.operations = [top, bottom]
        }
        let summary = try h.call("post_gcode", ["folder": h.allowed.path, "mode": "toolpath", "toolpath_id": bottomID.uuidString]).text
        #expect(summary.contains("SPOILBOARD"), "\(summary)")
        let sheet = try #require(try FileManager.default.contentsOfDirectory(atPath: h.allowed.path).first { $0.hasSuffix(" job sheet.html") })
        let html = try String(contentsOf: h.allowed.appendingPathComponent(sheet), encoding: .utf8)
        #expect(html.contains("<td>Bottom profile") && !html.contains("<td>Top profile"))
    }

    /// D: the job sheet's file name is made safe as the program's is (a "/" refused the whole post; "\\" is a separator on Windows).
    @Test func aProjectNameIsMadeSafeForTheSheetFileName() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 12, "height": 8, "thickness": 0.75, "name": #"A/B\C:D"#])
        let id = try #require(try h.json("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])["ids"] as? [String])
        try h.call("add_toolpath", ["kind": "profile", "shape_ids": id])
        try h.call("post_gcode", ["folder": h.allowed.path, "mode": "one_file"])
        let files = try FileManager.default.contentsOfDirectory(atPath: h.allowed.path)
        #expect(files.contains("A_B_C_D job sheet.html"), "\(files)")
    }

    /// F: Documents/LoftLine is made on first use even when Documents is a link (iCloud's Desktop & Documents does this).
    @Test func theDefaultFolderIsMadeWhenItsPathRunsThroughALink() throws {
        let root = Self.dir()
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Documents"), withDestinationURL: real)
        let def = root.appendingPathComponent("Documents/LoftLine")
        let access = AssistantAccess(settings: AssistantSettings(allowedFolders: [def.path]), defaultFolder: def)
        let target = try access.resolve(def.appendingPathComponent("x.tap").path)
        try AssistantWriter.write([GCodeFileSet.File(fileName: "x.tap", title: "x", text: "G0")], into: target.deletingLastPathComponent(),
                                  replace: false, access: access)
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("LoftLine/x.tap").path))
    }

    /// G: a settings file that exists but can't be read allows nothing, rather than falling back to the default folder.
    @Test func aDamagedSettingsFileAllowsNothing() throws {
        let file = Self.dir().appendingPathComponent("assistant.json")
        try Data("{not json".utf8).write(to: file)
        #expect(AssistantSettings.load(from: file).allowedFolders.isEmpty)
        let access = AssistantAccess(settingsFile: file)
        #expect { try access.resolve("/tmp/x.tap") } throws: { "\($0.localizedDescription)".contains("assistant.json") }
    }

    /// J: the Claude Code command quotes the path so a shell runs nothing in it.
    @Test func theClaudeCodeLineQuotesThePathForTheShell() {
        #if !os(Windows)
        #expect(AssistantSetup.claudeCodeLine(serverPath: "/Apps/$(touch x)/loftline-mcp") == "claude mcp add loftline -- '/Apps/$(touch x)/loftline-mcp'")
        #expect(AssistantSetup.claudeCodeLine(serverPath: "/Sean's Apps/loftline-mcp") == #"claude mcp add loftline -- '/Sean'\''s Apps/loftline-mcp'"#)
        #endif
    }

    /// K: absurd coordinates give a tool error, not a crash that loses the session.
    @Test func aPreviewOfHugeCoordinatesIsAnErrorNotACrash() {
        var p = LoftLineProject(document: Document())
        p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [Path(points: [Vec2(-1e308, 0), Vec2(1e308, 1)], closed: false)]))
        #expect(throws: (any Error).self) { try DesignPreview.render(project: p, toolpaths: [], width: 100, height: 100) }
    }
}
