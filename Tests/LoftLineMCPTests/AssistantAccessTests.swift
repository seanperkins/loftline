import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// Assistants read and write only inside the folders the user allows (MCP spec, "Safety").
@Suite struct AssistantAccessTests {
    /// A fresh real folder (symlinks resolved, so /var and /private/var compare equal) with an allowed `LoftLine` inside.
    static func sandbox() throws -> (root: URL, allowed: URL, access: AssistantAccess) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-access-\(UUID().uuidString)").resolvingSymlinksInPath()
        let allowed = root.appendingPathComponent("LoftLine")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        return (root, allowed, AssistantAccess(settings: AssistantSettings(allowedFolders: [allowed.path])))
    }

    @Test func aFileInsideIsAllowed() throws {
        let (_, allowed, access) = try Self.sandbox()
        let url = try access.resolve(allowed.appendingPathComponent("jobs/sign.loftline").path)
        #expect(url.path.hasSuffix("/LoftLine/jobs/sign.loftline"))
        // A relative path is taken inside the first allowed folder.
        let folder = try access.resolve("sign.tap").deletingLastPathComponent().standardizedFileURL.path
        let trimmed = { (p: String) in p.hasSuffix("/") ? String(p.dropLast()) : p }
        #expect(trimmed(folder) == trimmed(allowed.standardizedFileURL.path), "\(folder) is not \(allowed.path)")
    }

    @Test func dotDotIsRefused() throws {
        let (_, allowed, access) = try Self.sandbox()
        #expect(throws: AssistantAccessError.self) { try access.resolve(allowed.path + "/../secret.txt") }
        #expect(throws: AssistantAccessError.self) { try access.resolve(allowed.path + "/jobs/../sign.tap") }
    }

    @Test func aSymlinkPointingOutIsRefused() throws {
        let (root, allowed, access) = try Self.sandbox()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: allowed.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: AssistantAccessError.self) { try access.resolve(allowed.appendingPathComponent("link/x.tap").path) }
    }

    @Test func aSiblingWithTheSamePrefixIsRefused() throws {
        let (root, _, access) = try Self.sandbox()
        #expect(throws: AssistantAccessError.self) { try access.resolve(root.appendingPathComponent("LoftLine2/x.tap").path) }
    }

    @Test func aMissingSettingsFileAllowsTheDefaultFolder() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).json")
        let settings = AssistantSettings.load(from: file)
        #expect(settings.allowedFolders == [AssistantSettings.defaultFolder.path])
        #expect(AssistantSettings.defaultFolder.lastPathComponent == "LoftLine")
    }

    @Test func settingsRoundTrip() throws {
        let (root, allowed, _) = try Self.sandbox()
        let file = root.appendingPathComponent("support/assistant.json")
        try AssistantSettings(allowedFolders: [allowed.path]).save(to: file)
        #expect(AssistantSettings.load(from: file).allowedFolders == [allowed.path])
    }

    /// The writer's folder is checked as it is opened, by its real path: a folder outside is refused there too.
    @Test func anOpenedFolderOutsideIsRefusedAtWriteTime() throws {
        let (root, allowed, access) = try Self.sandbox()
        let ops = access.fileOperations()
        _ = try ops.openFolder(allowed)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(throws: AssistantAccessError.self) { _ = try ops.openFolder(outside) }
    }
}
