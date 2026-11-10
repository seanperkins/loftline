import Foundation
import Testing
@testable import LoftLineMCP

/// The MCP protocol over stdio, both generations (MCP spec, "Protocol").
///
/// Shapes from the published specification, read 2026-11-10:
/// https://modelcontextprotocol.io/specification/2026-07-28 (basic, basic/versioning, server/discover, server/tools,
/// basic/transports/stdio, changelog). 2026-07-28 removed `initialize`, `notifications/initialized` and `ping`; every request
/// carries `params._meta["io.modelcontextprotocol/protocolVersion"]` and `["io.modelcontextprotocol/clientCapabilities"]`;
/// results carry `resultType: "complete"` and `_meta["io.modelcontextprotocol/serverInfo"]`; an unsupported version is -32022
/// with `data: {supported, requested}`; discover and tools/list results are cacheable (`ttlMs`, `cacheScope`).
@Suite struct MCPServerTests {
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let modernMeta: [String: Any] = [
        versionKey: "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
    ]

    static func echo() -> AssistantTool {
        AssistantTool(name: "echo", description: "Says what it was given.",
                      inputSchema: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]) { args in
            ToolOutput(text: args["text"] as? String ?? "")
        }
    }

    static func failing() -> AssistantTool {
        AssistantTool(name: "fail", description: "Always fails.", inputSchema: ["type": "object", "additionalProperties": false]) { _ in
            throw AssistantAccessError(message: "It failed, as it always does.")
        }
    }

    static func picture() -> AssistantTool {
        AssistantTool(name: "picture", description: "A PNG.", inputSchema: ["type": "object"]) { _ in
            ToolOutput(text: "a picture", image: Data([0x89, 0x50, 0x4E, 0x47]))
        }
    }

    static let server = MCPServer(tools: [echo(), failing(), picture()], version: "1.2.3")

    static func send(_ object: [String: Any]) throws -> [String: Any]? {
        let line = try JSONSerialization.data(withJSONObject: object)
        guard let reply = server.handle(line) else { return nil }
        #expect(!reply.contains(0x0A), "a reply is one line")
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    static func modern(_ method: String, _ params: [String: Any] = [:], id: Any = "r1") throws -> [String: Any] {
        var p = params
        p["_meta"] = modernMeta
        return try #require(try send(["jsonrpc": "2.0", "id": id, "method": method, "params": p]))
    }

    @Test func initializeAnswersAKnownVersion() throws {
        let r = try #require(try Self.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                       "clientInfo": ["name": "c", "version": "1"]]]))
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "loftline")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "1.2.3")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(r["id"] as? Int == 1)
    }

    @Test func initializeFallsBackToTheNewestHandshakeVersion() throws {
        let r = try #require(try Self.send(["jsonrpc": "2.0", "id": 2, "method": "initialize",
                                            "params": ["protocolVersion": "2024-01-01", "capabilities": [String: Any]()]]))
        #expect((r["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.handshakeVersions.first)
    }

    @Test func discoverAnswersAsTheSpecShows() throws {
        let r = try Self.modern("server/discover", id: "discover-1")
        #expect(r["id"] as? String == "discover-1")
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["resultType"] as? String == "complete")
        #expect((result["supportedVersions"] as? [String])?.contains("2026-07-28") == true)
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect(((result["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String == "loftline")
        #expect(result["ttlMs"] is NSNumber && result["cacheScope"] is String)
    }

    @Test func aRequestCarryingTheVersionInMetaIsServed() throws {
        let r = try Self.modern("tools/list")
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["resultType"] as? String == "complete")
        #expect((result["tools"] as? [[String: Any]])?.map { $0["name"] as? String } == ["echo", "fail", "picture"])
        #expect(result["ttlMs"] is NSNumber)
    }

    @Test func anUnsupportedModernVersionIsRefused() throws {
        var meta = Self.modernMeta
        meta[Self.versionKey] = "1900-01-01"
        let r = try #require(try Self.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": ["_meta": meta]]))
        let error = try #require(r["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["requested"] as? String == "1900-01-01")
        #expect((data["supported"] as? [String])?.contains("2026-07-28") == true)
    }

    @Test func everyToolSchemaIsAnObjectWithItsRequiredFieldsListed() throws {
        for tool in Self.server.tools {
            #expect(tool.inputSchema["type"] as? String == "object", "\(tool.name)")
            let properties = tool.inputSchema["properties"] as? [String: Any] ?? [:]
            for name in tool.inputSchema["required"] as? [String] ?? [] { #expect(properties[name] != nil, "\(tool.name).\(name)") }
            #expect(tool.name.range(of: "^[a-z][a-z0-9_]{0,127}$", options: .regularExpression) != nil)
        }
    }

    @Test func aToolIsCalledAndAnswersWithText() throws {
        let r = try Self.modern("tools/call", ["name": "echo", "arguments": ["text": "hello"]])
        let result = try #require(r["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text" && content.first?["text"] as? String == "hello")
        #expect(result["isError"] as? Bool == false)
    }

    @Test func anImageComesBackAsBase64PNG() throws {
        let r = try Self.modern("tools/call", ["name": "picture", "arguments": [String: Any]()])
        let content = try #require((r["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image" })
        #expect(image["mimeType"] as? String == "image/png")
        #expect(image["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    }

    @Test func anUnknownToolIsInvalidParams() throws {
        let r = try Self.modern("tools/call", ["name": "nope", "arguments": [String: Any]()])
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func aThrowingToolIsAnErrorResultNotAProtocolError() throws {
        let r = try Self.modern("tools/call", ["name": "fail", "arguments": [String: Any]()])
        #expect(r["error"] == nil)
        let result = try #require(r["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(((result["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("It failed") == true)
    }

    @Test func anUnknownMethodIsMethodNotFound() throws {
        #expect((try Self.modern("prompts/list")["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func aMalformedLineIsAParseError() throws {
        let reply = try #require(Self.server.handle(Data("{not json".utf8)))
        let r = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect((r["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func aNotificationGetsNoReply() throws {
        #expect(try Self.send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(try Self.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "r1"]]) == nil)
    }

    @Test func pingAnswersOlderClients() throws {
        let r = try #require(try Self.send(["jsonrpc": "2.0", "id": 9, "method": "ping"]))
        #expect(r["result"] as? [String: Any] != nil)
    }
}
