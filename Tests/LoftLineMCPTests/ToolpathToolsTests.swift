import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct ToolpathToolsTests {
    static func panel(_ h: MCPHarness) throws -> String {
        try #require(h.session.project.document.shapes.first { $0.name == "Panel" }).id.uuidString
    }

    static func params(_ op: AnyOperation) throws -> [String: Any] {
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as? [String: Any])
        let inner = try #require((json.values.first as? [String: Any])?["_0"] as? [String: Any])
        return try #require(inner["params"] as? [String: Any])
    }

    @Test func mergeReplacesLeavesAndKeepsTheRest() {
        let merged = JSONPatch.merge(["a": ["b": 2, "gone": NSNull()], "c": 3], into: ["a": ["b": 1, "keep": true, "gone": 1], "d": 4])
        #expect((merged["a"] as? [String: Any])?["b"] as? Int == 2)
        #expect((merged["a"] as? [String: Any])?["keep"] as? Bool == true)
        #expect((merged["a"] as? [String: Any])?["gone"] == nil)
        #expect(merged["c"] as? Int == 3 && merged["d"] as? Int == 4)
    }

    @Test func addToolpathAppliesSettingsOverTheDefaults() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let before = h.session.project.operations.count
        let reply = try h.json("add_toolpath", ["kind": "pocket", "shape_ids": [try Self.panel(h)],
                                                "settings": ["params": ["depth": ["cutDepth": 0.1]]]])
        #expect(h.session.project.operations.count == before + 1)
        let op = try #require(h.session.project.operations.last)
        let params = try Self.params(op)
        #expect((params["depth"] as? [String: Any])?["cutDepth"] as? Double == 0.1)
        #expect(params["direction"] as? String == "climb", "the factory's other settings are kept")
        #expect(reply["id"] as? String == op.id.uuidString)
        #expect(reply["settings"] is [String: Any], "the reply shows the full settings the assistant can change")
        #expect(h.session.undoAction != nil)
    }

    @Test func anUnknownKindChangesNothing() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let ops = h.session.project.operations
        #expect(throws: (any Error).self) { try h.call("add_toolpath", ["kind": "laser", "shape_ids": [try Self.panel(h)]]) }
        #expect(h.session.project.operations == ops)
    }

    @Test func aBadSettingLeavesTheProjectAsItWas() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let ops = h.session.project.operations
        let undo = h.session.undoAction
        #expect(throws: (any Error).self) {
            try h.call("add_toolpath", ["kind": "pocket", "shape_ids": [try Self.panel(h)], "settings": ["params": ["depth": "deep"]]])
        }
        #expect(h.session.project.operations == ops)
        #expect(h.session.undoAction == undo)
    }

    @Test func updateToolpathDisablesMovesAndChanges() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let first = try #require(h.session.project.operations.first)
        try h.call("update_toolpath", ["id": first.id.uuidString, "enabled": false, "move_by": 1,
                                       "settings": ["setup": ["name": "Panel pocket"]]])
        let moved = try #require(h.session.project.operations.first { $0.id == first.id })
        #expect(!moved.setup.isEnabled)
        #expect(moved.setup.name == "Panel pocket")
        #expect(h.session.project.operations.firstIndex { $0.id == first.id } == 1)
        try h.call("delete_toolpath", ["id": first.id.uuidString])
        #expect(!h.session.project.operations.contains { $0.id == first.id })
    }

    @Test func calculateReportsTimeAndWarnings() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let rows = try #require(try h.json("calculate")["toolpaths"] as? [[String: Any]])
        #expect(rows.count == h.session.project.operations.count)
        #expect(rows.allSatisfy { $0["status"] as? String == "calculated" && ($0["time"] as? String)?.isEmpty == false })
    }

    @Test func listLibraryHasToolsPostsAndMachines() throws {
        let h = MCPHarness()
        try h.call("open_project", ["path": try h.sample().path])
        let posts = try #require(try h.json("list_library", ["kind": "posts"])["posts"] as? [[String: Any]])
        #expect(posts.contains { $0["id"] as? String == "generic-grbl-inch" })
        let tools = try #require(try h.json("list_library", ["kind": "tools"])["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["number"] as? Int == 1 })
        #expect(!(try #require(try h.json("list_library", ["kind": "machines"])["machines"] as? [[String: Any]])).isEmpty)
    }
}
