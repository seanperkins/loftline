import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct ProjectToolsTests {
    @Test func openRefusesToDropUnsavedChanges() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        h.session.perform("Edit") { $0.document.name = "Changed" }
        #expect { try h.call("open_project", ["path": try h.sample().path]) } throws: { "\($0.localizedDescription)".contains("unsaved") }
        #expect { try h.call("new_project", ["units": "inch", "width": 10, "height": 10, "thickness": 0.5]) } throws: { _ in true }
        try h.call("open_project", ["path": try h.sample().path, "discard": true])
        #expect(!h.session.isDirty)
    }

    @Test func newProjectSetsUnitsAndMaterial() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "millimeter", "width": 600, "height": 400, "thickness": 18, "name": "Shelf"])
        let doc = h.session.project.document
        #expect(doc.units == .millimeter && doc.job.width == 600 && doc.job.height == 400 && doc.job.thickness == 18)
        #expect(doc.name == "Shelf")
        #expect(doc.job.safeZ > 1, "safe Z converted to millimetres, not left as 0.2")
    }

    @Test func saveOutsideTheAllowedFoldersIsRefused() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        #expect(throws: AssistantAccessError.self) { try h.call("save_project", ["path": h.outside.appendingPathComponent("x.loftline").path]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.outside.path).isEmpty)
    }

    @Test func saveOverAnExistingFileNeedsReplace() throws {
        let h = MCPHarness()
        let own = try h.sample()
        try h.call("open_project", ["path": own.path])
        h.session.perform("Edit") { $0.document.name = "Edited" }
        try h.call("save_project")   // its own file: no replace needed
        let other = h.allowed.appendingPathComponent("other.loftline")
        try Data("old".utf8).write(to: other)
        #expect { try h.call("save_project", ["path": other.path]) } throws: { "\($0.localizedDescription)".contains("replace") }
        #expect(try String(contentsOf: other, encoding: .utf8) == "old")
        try h.call("save_project", ["path": other.path, "replace": true])
        #expect(try LoftLineProject.opening(from: Data(contentsOf: other)).document.name == "Edited")
    }

    @Test func saveWritesThroughTheFolderWriter() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 12, "height": 8, "thickness": 0.75])
        let to = h.allowed.appendingPathComponent("jobs")
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        try h.call("save_project", ["path": to.appendingPathComponent("plate").path])
        #expect(FileManager.default.fileExists(atPath: to.appendingPathComponent("plate.loftline").path))
        #expect(try h.json("describe_project")["unsaved"] as? Bool == false)
    }

    @Test func describeListsClampsByTheirSheetNames() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let clamps = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 1.5))
        h.session.perform("Clamps") { p in
            p.document.layers.append(clamps)
            p.document.add(Shape(layerID: clamps.id, paths: [ShapeFactory.rectangle(Rect2(x: -2, y: 11, width: 3, height: 2))]))
            p.document.add(Shape(layerID: clamps.id, paths: [ShapeFactory.rectangle(Rect2(x: 23, y: 4, width: 2, height: 2))]))
        }
        let d = try h.json("describe_project")
        let listed = try #require(d["clamps"] as? [[String: Any]])
        #expect(listed.map { $0["name"] as? String } == ["Clamp 1", "Clamp 2"])
        #expect(listed.first?["position"] as? String == "left edge, centre 12 in from the bottom, reaches 1 in onto the material")
        #expect(listed.first?["height"] as? String == "1.5 in above the material")
    }

    @Test func describePages() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        h.session.perform("Many") { p in
            for i in 0..<250 { p.document.add(Shape(layerID: p.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: Double(i % 20), y: Double(i / 20), width: 0.5, height: 0.5))])) }
        }
        let first = try h.json("describe_project")
        #expect((first["shapes"] as? [[String: Any]])?.count == 200)
        #expect(first["moreShapes"] as? Int == 50)
        let second = try h.json("describe_project", ["offset": 200])
        #expect((second["shapes"] as? [[String: Any]])?.count == 50)
    }

    @Test func undoTakesBackTheLastChange() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let before = h.session.project.document.shapes.count
        h.session.perform("Add") { $0.document.add(Shape(layerID: $0.document.defaultLayerID, paths: [ShapeFactory.rectangle(Rect2(x: 1, y: 1, width: 1, height: 1))])) }
        #expect(try h.call("undo").text.contains("Add"))
        #expect(h.session.project.document.shapes.count == before)
    }
}
