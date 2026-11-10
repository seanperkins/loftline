import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct OutputToolsTests {
    static func files(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    /// Every built-in post: the sign posted through the tools is byte for byte the program the Mac committed.
    @Test func postingTheSampleMatchesExpectedForEveryBuiltInPost() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let expectedRoot = MCPHarness.root.appendingPathComponent("samples/expected")
        var checked = 0
        for profile in h.session.profiles {
            let dir = expectedRoot.appendingPathComponent(profile.id)
            guard let name = Self.files(dir).first(where: { $0.hasPrefix("sign.") }) else { continue }
            let out = h.allowed.appendingPathComponent(profile.id)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try h.call("post_gcode", ["folder": out.path, "mode": "one_file", "post_id": profile.id, "job_sheet": false])
            let written = Self.files(out)
            #expect(written.count == 1, "\(profile.id): \(written)")
            let got = try Data(contentsOf: out.appendingPathComponent(try #require(written.first)))
            #expect(got == (try Data(contentsOf: dir.appendingPathComponent(name))), "\(profile.id)")
            checked += 1
        }
        #expect(checked >= 10)
    }

    @Test func aPostTellsTheOperatorWhatToCheckAndWritesTheJobSheet() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let out = try h.call("post_gcode", ["folder": h.allowed.path, "mode": "one_file"]).text
        for word in ["Machine:", "Post:", "Material:", "Z zero:", "Deepest cut:", "Time:", "Tool changes:", "air cut"] {
            #expect(out.contains(word), "\(word) in \(out)")
        }
        #expect(Self.files(h.allowed).contains { $0.hasSuffix(" job sheet.html") })
    }

    @Test func aProgramWithAnErrorWritesNothing() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        h.session.perform("Short flutes") { p in for i in p.tools.indices { p.tools[i].fluteLength = 0.01 } }
        let out = h.allowed.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try h.call("post_gcode", ["folder": out.path, "mode": "one_file"]) }
        #expect(Self.files(out).isEmpty)
    }

    @Test func aMissingPostWritesNothing() throws {
        let h = MCPHarness()
        let file = try h.sample()
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["postProfileID"] = "gone-post"
        object["postSnapshot"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try h.call("open_project", ["path": file.path])
        let out = h.allowed.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #expect { try h.call("post_gcode", ["folder": out.path, "mode": "per_tool"]) } throws: { "\($0.localizedDescription)".contains("not installed") }
        #expect(Self.files(out).isEmpty)
        #expect(try h.call("check").text.contains("error"))
    }

    /// A folder that passed the check and was then swapped for a link out is refused when the writer opens it.
    @Test func aFolderSwappedForALinkIsRefused() throws {
        let h = MCPHarness()
        let sub = h.allowed.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try h.access.resolve(sub.appendingPathComponent("x.tap").path)
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: h.outside)
        #expect(throws: (any Error).self) {
            try AssistantWriter.write([GCodeFileSet.File(fileName: "x.tap", title: "x", text: "G0")], into: sub, replace: false, access: h.access)
        }
        #expect(Self.files(h.outside).isEmpty)
    }

    @Test func anExistingFileNeedsReplace() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let out = h.allowed.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try h.call("post_gcode", ["folder": out.path, "mode": "one_file", "job_sheet": false])
        let name = try #require(Self.files(out).first)
        try Data("old".utf8).write(to: out.appendingPathComponent(name))
        #expect { try h.call("post_gcode", ["folder": out.path, "mode": "one_file", "job_sheet": false]) } throws: { "\($0.localizedDescription)".contains("replace") }
        #expect(try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8) == "old")
        try h.call("post_gcode", ["folder": out.path, "mode": "one_file", "job_sheet": false, "replace": true])
        #expect(try String(contentsOf: out.appendingPathComponent(name), encoding: .utf8) != "old")
    }

    /// Per tool and grouped: the job sheet beside the programs lists the steps in the programs' order.
    @Test func theJobSheetBesideTheProgramUsesItsContext() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        try h.call("post_gcode", ["folder": h.allowed.path, "mode": "per_tool", "group_by_tool": true])
        let sheet = try #require(Self.files(h.allowed).first { $0.hasSuffix(" job sheet.html") })
        let html = try String(contentsOf: h.allowed.appendingPathComponent(sheet), encoding: .utf8)
        let order = h.session.previewToolpaths(groupByTool: true).map(\.name)
        let at = order.compactMap { html.range(of: "<td>\($0)")?.lowerBound }
        #expect(at.count == order.count && at == at.sorted(), "\(order)")
        // Per tool runs: the profile on T1 never moves before the other tools, so T1 has two files, in the sheet's order.
        let programs = Self.files(h.allowed).filter { $0.hasSuffix(".tap") }
        #expect(programs.count == 4 && programs.first?.hasPrefix("01_") == true && programs.last?.hasPrefix("04_") == true, "\(programs)")
    }

    @Test func theBottomSideIsPostedAlone() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        h.session.perform("Two-sided") { p in
            var form = JobSetupForm(document: p.document)
            form.job.twoSided = TwoSidedSetup(flip: .leftRight, bottomZZero: .spoilboard)
            p = form.apply(to: p)
            let bottomLayer = p.document.layers.first { $0.side == .bottom }!.id
            p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 2, height: 1))]))
            p.document.add(Shape(layerID: bottomLayer, paths: [ShapeFactory.rectangle(Rect2(x: 5, y: 1, width: 2, height: 1))]))
            let top = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[0].id])!
            var bottom = OperationFactory.make(kind: .profile, project: p, library: h.session.library, shapeIDs: [p.document.shapes[1].id])!
            var setup = bottom.editableSetup
            setup.name = "Bottom profile"
            bottom.editableSetup = setup
            p.operations = [top, bottom]
        }
        try h.call("post_gcode", ["folder": h.allowed.path, "mode": "per_toolpath", "side": "bottom"])
        let programs = Self.files(h.allowed).filter { !$0.hasSuffix(".html") }
        #expect(programs.count == 1 && programs[0].contains("Bottom_profile"), "\(programs)")
        let sheet = try #require(Self.files(h.allowed).first { $0.hasSuffix(" job sheet.html") })
        #expect(try String(contentsOf: h.allowed.appendingPathComponent(sheet), encoding: .utf8).contains("(Bottom side)"))
    }

    @Test func checkReportsWhatTheMacReports() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        h.session.perform("Outside") { p in
            p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 30, y: 2, width: 2, height: 2))]))
        }
        let before = Self.files(h.allowed)
        #expect(try h.call("check").text.contains("entirely outside the material"))
        #expect(Self.files(h.allowed) == before)
    }

    @Test func aJobSheetAloneGoesWhereItIsAsked() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        try h.call("job_sheet", ["path": h.allowed.appendingPathComponent("sheet.html").path])
        #expect(FileManager.default.fileExists(atPath: h.allowed.appendingPathComponent("sheet.html").path))
        #expect(throws: AssistantAccessError.self) { try h.call("job_sheet", ["path": h.outside.appendingPathComponent("sheet.html").path]) }
    }
}
