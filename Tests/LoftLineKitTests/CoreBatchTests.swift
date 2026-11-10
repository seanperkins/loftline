import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

/// `addShapes`: a batch is checked whole, then added as one undoable change (MCP spec, "One change per call").
@Suite struct CoreBatchTests {
    typealias T = CoreServiceTests

    static let three: [[String: Any]] = [
        ["kind": "tool", "tool": "rectangle", "from": ["x": 1, "y": 1], "to": ["x": 3, "y": 2]],
        ["kind": "polyline", "points": [["x": 5, "y": 1], ["x": 7, "y": 1], ["x": 6, "y": 3]], "closed": true],
        ["kind": "tool", "tool": "circle", "from": ["x": 10, "y": 10], "to": ["x": 11, "y": 10]],
    ]

    @Test func aBatchAddsInOneUndoStep() throws {
        let s = T.service()
        let before = s.session.project.document.shapes.count
        let reply = try T.result(T.call(s, "addShapes", ["shapes": Self.three]))
        let ids = try #require(reply["ids"] as? [String])
        #expect(ids.count == 3)
        #expect(s.session.project.document.shapes.count == before + 3)
        let polygon = try #require(s.session.project.document.shapes.first { $0.id.uuidString == ids[1] })
        #expect(polygon.isClosed)
        _ = try T.result(T.call(s, "undo"))
        #expect(s.session.project.document.shapes.count == before)
    }

    @Test func aBadItemLeavesTheProjectAsItWas() throws {
        let s = T.service()
        _ = try T.result(T.call(s, "addShapes", ["shapes": [Self.three[0]]]))
        let shapes = s.session.project.document.shapes
        let undo = s.session.undoAction
        var bad = Self.three
        bad[1] = ["kind": "polyline", "points": [["x": 5, "y": 1]], "closed": false]
        let reply = try T.call(s, "addShapes", ["shapes": bad])
        #expect((reply["error"] as? String)?.contains("Shape 2") == true, "\(reply)")
        #expect(s.session.project.document.shapes == shapes)
        #expect(s.session.undoAction == undo)
    }

    @Test func aShapeCanGoOnAGivenLayer() throws {
        let s = T.service()
        let layer = Layer(name: "Clamps", keepOut: LayerKeepOut(height: 1))
        s.session.perform("Layer") { $0.document.layers.append(layer) }
        var item = Self.three[0]
        item["layerID"] = layer.id.uuidString
        let reply = try T.result(T.call(s, "addShapes", ["shapes": [item]]))
        let id = try #require((reply["ids"] as? [String])?.first)
        #expect(s.session.project.document.shapes.first { $0.id.uuidString == id }?.layerID == layer.id)
    }
}
