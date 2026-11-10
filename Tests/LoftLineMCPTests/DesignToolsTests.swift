import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct DesignToolsTests {
    /// The 24 x 12 in sign changed to millimetres with no sizes given: the job and the design convert once, as Job Setup does.
    @Test func setJobConvertsUnitsFirst() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let before = h.session.project.document.shapes[0].bounds()
        try h.call("set_job", ["units": "millimeter"])
        let doc = h.session.project.document
        #expect(doc.units == .millimeter)
        #expect(abs(doc.job.width - 609.6) < 1e-9 && abs(doc.job.height - 304.8) < 1e-9)
        #expect(abs(doc.shapes[0].bounds().width - before.width * 25.4) < 1e-6)
        // Then a size in the new units is taken as it is.
        try h.call("set_job", ["thickness": 18])
        #expect(h.session.project.document.job.thickness == 18)
    }

    @Test func setJobRejectsWhatJobSetupRejects() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let job = h.session.project.document.job
        #expect(throws: (any Error).self) { try h.call("set_job", ["thickness": 0]) }
        #expect(h.session.project.document.job == job)
    }

    @Test func addShapesBuildsEachKind() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let reply = try h.json("add_shapes", ["shapes": [
            ["type": "rectangle", "x": 1, "y": 2, "width": 4, "height": 3],
            ["type": "rounded_rectangle", "x": 6, "y": 2, "width": 4, "height": 3, "corner_radius": 0.5],
            ["type": "circle", "x": 12, "y": 4, "radius": 1.5],
            ["type": "ellipse", "x": 16, "y": 4, "radius_x": 2, "radius_y": 1],
            ["type": "polygon", "x": 20, "y": 4, "radius": 1, "sides": 6],
            ["type": "star", "x": 20, "y": 10, "radius": 1, "points": 5],
            ["type": "polyline", "points": [["x": 1, "y": 10], ["x": 4, "y": 10], ["x": 2.5, "y": 13]], "closed": true],
            ["type": "text", "text": "HI", "x": 8, "y": 10, "size": 2],
        ]])
        let ids = try #require(reply["ids"] as? [String])
        #expect(ids.count == 8)
        let rect = try #require(h.session.project.document.shapes.first { $0.id.uuidString == ids[0] })
        #expect(rect.bounds() == Rect2(x: 1, y: 2, width: 4, height: 3))
        let circle = try #require(h.session.project.document.shapes.first { $0.id.uuidString == ids[2] })
        #expect(abs(circle.bounds().width - 3) < 1e-6)
    }

    @Test func addShapesOverTheLimitIsAnErrorAndAddsNothing() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let one: [String: Any] = ["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1]
        #expect(throws: (any Error).self) { try h.call("add_shapes", ["shapes": Array(repeating: one, count: 201)]) }
        let many = (0...10_000).map { ["x": Double($0) * 0.001, "y": 0] }
        #expect(throws: (any Error).self) { try h.call("add_shapes", ["shapes": [["type": "polyline", "points": many]]]) }
        #expect(throws: (any Error).self) {
            try h.call("add_shapes", ["shapes": [["type": "text", "text": String(repeating: "A", count: 1_001), "x": 1, "y": 1, "size": 1]]])
        }
        #expect(h.session.project.document.shapes.isEmpty)
    }

    @Test func editShapesMovesRotatesAndDeletes() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let ids = try #require(try h.json("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 4, "height": 2]]])["ids"] as? [String])
        try h.call("edit_shapes", ["action": "move", "ids": ids, "dx": 2, "dy": 3])
        #expect(h.session.project.document.shapes[0].bounds() == Rect2(x: 3, y: 4, width: 4, height: 2))
        try h.call("edit_shapes", ["action": "rotate", "ids": ids, "degrees": 90])
        #expect(abs(h.session.project.document.shapes[0].bounds().width - 2) < 1e-6)
        try h.call("edit_shapes", ["action": "scale", "ids": ids, "factor": 2])
        #expect(abs(h.session.project.document.shapes[0].bounds().height - 8) < 1e-6)
        try h.call("edit_shapes", ["action": "delete", "ids": ids])
        #expect(h.session.project.document.shapes.isEmpty)
        #expect(throws: (any Error).self) { try h.call("edit_shapes", ["action": "melt", "ids": ids]) }
    }

    @Test func importFromOutsideIsRefused() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let svg = h.outside.appendingPathComponent("a.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="2in" height="1in"><rect width="2" height="1"/></svg>"#.utf8).write(to: svg)
        #expect(throws: AssistantAccessError.self) { try h.call("import_file", ["path": svg.path]) }
    }

    @Test func anImportOver50MBIsRefusedUnread() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let big = h.allowed.appendingPathComponent("big.svg")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 50 * 1_048_576 + 1)
        try handle.close()
        #expect { try h.call("import_file", ["path": big.path]) } throws: { "\($0.localizedDescription)".contains("50 MB") }
    }

    @Test func markingALayerAsClampsSetsItsHeight() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let added = try h.json("edit_layers", ["action": "add", "name": "Clamps"])
        let id = try #require(added["id"] as? String)
        try h.call("edit_layers", ["action": "clamps", "id": id, "height": 1.5])
        #expect(h.session.project.document.layers.first { $0.id.uuidString == id }?.keepOut?.height == 1.5)
        try h.call("edit_layers", ["action": "hide", "id": id])
        #expect(h.session.project.document.layers.first { $0.id.uuidString == id }?.isVisible == false)
    }
}
