import Foundation
import Testing
import LoftLineKit
@testable import LoftLineMCP

/// The deferred minors of the MCP review (PR #139), each pinned before its fix.
@Suite struct MinorFixTests {
    @Test func aRequestWithANullIDGetsAnErrorNotSilence() throws {
        let reply = try #require(MCPServerTests.server.handle(Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#.utf8)))
        let r = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect(r["id"] is NSNull)
    }

    @Test func aMalformedShapeItemIsRefusedAndNothingIsAdded() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        #expect(throws: (any Error).self) {
            try h.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1], "oops"]])
        }
        #expect(h.session.project.document.shapes.isEmpty)
    }

    @Test func aClosedPolylineNeedsThreePoints() throws {
        let h = MCPHarness()
        try h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        #expect(throws: (any Error).self) {
            try h.call("add_shapes", ["shapes": [["type": "polyline", "points": [["x": 0, "y": 0], ["x": 1, "y": 0]], "closed": true]]])
        }
        #expect(h.session.project.document.shapes.isEmpty)
    }

    @Test func theCheckReportRequestRefusesBadParameters() throws {
        let h = MCPHarness()
        let reply = h.service.handle(Data(#"{"id":1,"method":"checkReport","params":{"side":"left"}}"#.utf8))
        let r = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(r["error"] != nil)
        let plain = h.service.handle(Data(#"{"id":2,"method":"checkReport"}"#.utf8))
        #expect((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["result"] != nil)
    }

    /// Off the Mac nothing tells the server its version, so the setup the desktop shows passes it.
    @Test func theSetupCarriesTheAppVersionWhenGiven() throws {
        let path = "/opt/loftline/loftline-mcp"
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AssistantSetup.config(serverPath: path, version: "0.3.0").utf8)) as? [String: Any])
        let server = (object["mcpServers"] as? [String: Any])?["loftline"] as? [String: Any]
        #expect(server?["args"] as? [String] == ["--version", "0.3.0"])
        #expect(AssistantSetup.claudeCodeLine(serverPath: path, version: "0.3.0").hasSuffix("--version 0.3.0"))
        #expect(MCPServer.appVersion(arguments: ["loftline-mcp", "--version", "0.3.0"], executable: nil) == "0.3.0")
    }
}
