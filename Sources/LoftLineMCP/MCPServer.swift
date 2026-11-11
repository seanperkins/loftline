import Foundation

/// The Model Context Protocol over stdio, one JSON-RPC message per line, in both generations: 2026-07-28 (no handshake; each
/// request names its version in `_meta`; `server/discover`) and the `initialize` handshake of earlier revisions. A request
/// that carries a version in `_meta` is answered as 2026-07-28; one without is answered as the handshake generation. Bad input
/// gets an error reply and never ends the server.
public final class MCPServer {
    public static let modernVersions = ["2026-07-28"]
    /// Newest first: `initialize` with a version not listed is answered with the first.
    public static let handshakeVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    public let tools: [AssistantTool]
    public let version: String

    public init(tools: [AssistantTool], version: String) {
        self.tools = tools
        self.version = version
    }

    struct Failure: Error {
        var code: Int
        var message: String
        var data: [String: Any]? = nil
    }

    /// The reply to one line, or nil for a notification.
    public func handle(_ line: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: line), let message = object as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error: not a JSON object."]])
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32600, "message": "Invalid request: no method."]])
        }
        guard let id, id is String || id is NSNumber else { return nil }   // a notification: no reply
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try answer(method, params: params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let f as Failure {
            var error: [String: Any] = ["code": f.code, "message": f.message]
            if let data = f.data { error["data"] = data }
            return encode(["jsonrpc": "2.0", "id": id, "error": error])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error.localizedDescription)"]])
        }
    }

    func answer(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let meta = params["_meta"] as? [String: Any]
        if let requested = meta?[Self.versionKey] as? String {
            guard Self.modernVersions.contains(requested) else {
                throw Failure(code: -32022, message: "Unsupported protocol version",
                              data: ["supported": Self.modernVersions + Self.handshakeVersions, "requested": requested])
            }
            guard meta?[Self.capabilitiesKey] is [String: Any] else {
                throw Failure(code: -32602, message: "Invalid params: _meta needs \"\(Self.capabilitiesKey)\".")
            }
            var result = try modern(method, params: params)
            result["resultType"] = "complete"
            var resultMeta = result["_meta"] as? [String: Any] ?? [:]
            resultMeta[Self.serverInfoKey] = serverInfo
            result["_meta"] = resultMeta
            return result
        }
        return try handshake(method, params: params)
    }

    var serverInfo: [String: Any] { ["name": "loftline", "version": version] }
    var capabilities: [String: Any] { ["tools": [String: Any]()] }

    /// 2026-07-28.
    func modern(_ method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "server/discover":
            return ["supportedVersions": Self.modernVersions + Self.handshakeVersions, "capabilities": capabilities,
                    "instructions": Self.instructions, "ttlMs": 3_600_000, "cacheScope": "private"]
        case "tools/list":
            var list = try call("tools/list", params: params)
            list["ttlMs"] = 3_600_000
            list["cacheScope"] = "private"
            return list
        case "tools/call":
            return try call(method, params: params)
        default:
            throw Failure(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The `initialize` generation (2025-11-25 back to 2024-11-05).
    func handshake(_ method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.handshakeVersions.contains(asked) ? asked : Self.handshakeVersions[0]
            return ["protocolVersion": version, "capabilities": capabilities, "serverInfo": serverInfo, "instructions": Self.instructions]
        case "ping":
            return [:]
        case "tools/list", "tools/call":
            return try call(method, params: params)
        default:
            throw Failure(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// tools/list and tools/call, the same in both generations.
    func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
        if method == "tools/list" {
            return ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema] }]
        }
        guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
            throw Failure(code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "(none)")")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let out = try tool.call(arguments)
            var content: [[String: Any]] = [["type": "text", "text": out.text]]
            if let png = out.image { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            return ["content": content, "isError": false]
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return ["content": [["type": "text", "text": text]], "isError": true]
        }
    }

    static let instructions = "LoftLine designs and posts CNC router programs. Every program is checked as the LoftLine app checks it, "
        + "and one with an error is never written. Files are read and written only in the folders the user allows; a document open in "
        + "LoftLine, once the user allows it with use_open_document, is read and edited wherever its file is. After posting, "
        + "show the user the summary and the job sheet; they check the program and do an air cut before cutting."

    func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: could not encode the reply."}}"#.utf8)
    }

    /// The app's version: `CFBundleShortVersionString` of the LoftLine.app around the executable, else a `--version` argument,
    /// else "dev".
    public static func appVersion(arguments: [String] = CommandLine.arguments, executable: URL? = Bundle.main.executableURL) -> String {
        if let exe = executable {
            let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: plist),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let v = info["CFBundleShortVersionString"] as? String { return v }
        }
        if let i = arguments.firstIndex(of: "--version"), i + 1 < arguments.count { return arguments[i + 1] }
        return "dev"
    }
}
