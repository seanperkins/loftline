import Foundation
import Testing
@testable import LoftLineMCP

/// What Help > Connect an AI Assistant… shows: the same text on the Mac and in the desktop app.
@Suite struct AssistantSetupTests {
    @Test func theConfigNamesTheBundledServer() throws {
        let path = "/Applications/LoftLine.app/Contents/MacOS/loftline-mcp"
        let config = AssistantSetup.config(serverPath: path)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let server = ((object["mcpServers"] as? [String: Any])?["loftline"] as? [String: Any])
        #expect(server?["command"] as? String == path)
        #expect(AssistantSetup.claudeCodeLine(serverPath: path) == #"claude mcp add loftline -- "/Applications/LoftLine.app/Contents/MacOS/loftline-mcp""#)
    }

    @Test func aWindowsPathIsEscapedInTheConfig() throws {
        let path = #"C:\Program Files\LoftLine\loftline-mcp.exe"#
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AssistantSetup.config(serverPath: path).utf8)) as? [String: Any])
        #expect(((object["mcpServers"] as? [String: Any])?["loftline"] as? [String: Any])?["command"] as? String == path)
    }

    @Test func theServerSitsBesideTheAppsExecutable() {
        let exe = URL(fileURLWithPath: "/Applications/LoftLine.app/Contents/MacOS/LoftLine")
        #expect(AssistantSetup.serverPath(besideExecutable: exe) == "/Applications/LoftLine.app/Contents/MacOS/loftline-mcp")
    }
}
