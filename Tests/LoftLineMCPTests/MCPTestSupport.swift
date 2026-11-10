import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// A server's tools over an isolated engine (no user posts, machines or tools) and a fresh allowed folder.
struct MCPHarness {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let service: CoreService
    let access: AssistantAccess
    let allowed: URL
    let outside: URL
    let tools: [AssistantTool]

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)").resolvingSymlinksInPath()
        allowed = dir.appendingPathComponent("LoftLine")
        outside = dir.appendingPathComponent("outside")
        try? FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var posts = PostProfileStore(directory: dir.appendingPathComponent("posts"))
        posts.readsUserFiles = false
        var machines = MachineStore(directory: dir.appendingPathComponent("machines"))
        machines.readsUserFiles = false
        service = CoreService(session: CoreSession(toolStore: ToolLibraryStore(fileURL: dir.appendingPathComponent("tools.json")),
                                                   postStore: posts, machineStore: machines))
        access = AssistantAccess(settings: AssistantSettings(allowedFolders: [allowed.path]))
        tools = AssistantTools.all(service: service, access: access)
    }

    var session: CoreSession { service.session }

    @discardableResult
    func call(_ name: String, _ args: [String: Any] = [:]) throws -> ToolOutput {
        let tool = try #require(tools.first { $0.name == name }, "no tool \(name)")
        return try tool.call(args)
    }

    /// The JSON after a tool's summary line.
    func json(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let text = try call(name, args).text
        let body = text.split(separator: "\n", maxSplits: 1).dropFirst().first.map(String.init) ?? "{}"
        return try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    /// A copy of a sample inside the allowed folder.
    func sample(_ name: String = "sign") throws -> URL {
        let to = allowed.appendingPathComponent("\(name).loftline")
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: Self.root.appendingPathComponent("samples/\(name).loftline"), to: to)
        return to
    }
}
