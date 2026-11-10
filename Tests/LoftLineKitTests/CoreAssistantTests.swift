import Foundation
import Testing
@testable import LoftLineKit

/// The desktop app's Help > Connect an AI Assistant… reads and sets the allowed folders through the core.
@Suite struct CoreAssistantTests {
    @Test func assistantFoldersRoundTrip() throws {
        let s = CoreServiceTests.service()
        let dir = AppTestSupport.tempDir()
        s.assistantSettingsURL = dir.appendingPathComponent("support/assistant.json")
        let first = try CoreServiceTests.result(CoreServiceTests.call(s, "assistantSetup"))
        #expect(first["allowedFolders"] as? [String] == [AssistantSettings.defaultFolder.path])
        #expect((first["serverPath"] as? String)?.contains("loftline-mcp") == true)
        #expect((first["config"] as? String)?.contains("mcpServers") == true)
        #expect((first["claudeCodeLine"] as? String)?.hasPrefix("claude mcp add loftline -- ") == true)
        let folder = dir.appendingPathComponent("Jobs").path
        let set = try CoreServiceTests.result(CoreServiceTests.call(s, "setAssistantFolders", ["folders": [folder]]))
        #expect(set["allowedFolders"] as? [String] == [folder])
        #expect(AssistantSettings.load(from: s.assistantSettingsURL).allowedFolders == [folder])
    }
}
