import Foundation
import LoftLineKit
import LoftLineMCP

// The MCP server for AI assistants: one JSON-RPC message per line on standard input, one reply per line on standard output.
// Nothing else goes to standard output; messages for people go to standard error. It ends when standard input closes.
let service = CoreService()
let access = AssistantAccess(settings: AssistantSettings.load())
let server = MCPServer(tools: AssistantTools.all(service: service, access: access), version: MCPServer.appVersion())
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let reply = server.handle(Data(line.utf8)) else { continue }
    FileHandle.standardOutput.write(reply)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
