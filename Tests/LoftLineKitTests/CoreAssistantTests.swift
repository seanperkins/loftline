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

    /// The live-link switch (spec 2, "The switch").
    @Test func anOldSettingsFileKeepsItsFoldersAndIsOff() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("assistant.json")
        try Data(#"{"allowedFolders":["/x"]}"#.utf8).write(to: url)
        let s = AssistantSettings.load(from: url)
        #expect(s.allowedFolders == ["/x"])
        #expect(s.liveLink == false)
    }

    @Test func settingFoldersKeepsTheSwitch() throws {
        let s = CoreServiceTests.service()
        s.assistantSettingsURL = AppTestSupport.tempDir().appendingPathComponent("support/assistant.json")
        let on = try CoreServiceTests.result(CoreServiceTests.call(s, "setAssistantLink", ["on": true]))
        #expect(on["liveLink"] as? Bool == true)
        let after = try CoreServiceTests.result(CoreServiceTests.call(s, "setAssistantFolders", ["folders": ["/jobs"]]))
        #expect(after["liveLink"] as? Bool == true)
        let saved = AssistantSettings.load(from: s.assistantSettingsURL)
        #expect(saved.liveLink && saved.allowedFolders == ["/jobs"])
    }

    @Test func aDamagedFileIsOff() throws {
        let url = AppTestSupport.tempDir().appendingPathComponent("assistant.json")
        try Data("{not json".utf8).write(to: url)
        let s = AssistantSettings.load(from: url)
        #expect(s.allowedFolders.isEmpty)
        #expect(s.liveLink == false)
    }

    @Test func theLinkFolderSitsBesideTheSettings() {
        let url = URL(fileURLWithPath: "/tmp/x/assistant.json")
        #expect(AssistantSettings.linkFolder(for: url).path == "/tmp/x/link")
    }
}
