import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

@Suite struct HelpToolTests {
    @Test func helpListsTopicsAndReturnsOne() throws {
        let h = MCPHarness()
        let list = try h.json("help")
        let ids = (list["topics"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        #expect(ids.contains("assistant") && ids.contains("pocket"))
        let pocket = try h.call("help", ["topic": "pocket"]).text
        #expect(pocket.contains("Pocket Toolpath") && pocket.count > 200)
        #expect(throws: (any Error).self) { try h.call("help", ["topic": "nope"]) }
    }

    @Test func theAssistantTopicStatesTheRules() {
        let body = HelpTopic.assistant.body
        #expect(body.contains("never writes a program with an error"))
        #expect(body.contains("allowed folders"))
        #expect(body.contains("air cut"))
        #expect(body.contains("Connect an AI Assistant"))
    }

    /// Every tool the server offers has a valid schema and a name assistants accept.
    @Test func everyToolIsWellFormed() {
        let h = MCPHarness()
        let names = h.tools.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.count == 20, "\(names)")
        for tool in h.tools {
            #expect(tool.inputSchema["type"] as? String == "object", "\(tool.name)")
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            for name in tool.inputSchema["required"] as? [String] ?? [] { #expect(properties[name] != nil, "\(tool.name).\(name)") }
            #expect(tool.name.range(of: "^[a-z][a-z0-9_]{0,127}$", options: .regularExpression) != nil)
            #expect(tool.description.count > 20, "\(tool.name)")
            #expect(JSONSerialization.isValidJSONObject(tool.inputSchema), "\(tool.name)")
        }
    }
}
