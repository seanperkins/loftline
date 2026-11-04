import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

/// The desktop app's protocol: G-code from the sidecar is the program the exporter makes, and bad input never ends the process.
@Suite struct CoreServiceTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func service() -> CoreService {
        let dir = AppTestSupport.tempDir()
        var posts = PostProfileStore(directory: dir.appendingPathComponent("posts"))
        posts.readsUserFiles = false
        var machines = MachineStore(directory: dir.appendingPathComponent("machines"))
        machines.readsUserFiles = false
        return CoreService(session: CoreSession(toolStore: ToolLibraryStore(fileURL: dir.appendingPathComponent("tools.json")),
                                                postStore: posts, machineStore: machines))
    }

    static func call(_ service: CoreService, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let reply = service.handle(line)
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    static func result(_ reply: [String: Any]) throws -> [String: Any] {
        #expect(reply["error"] == nil, "\(reply["error"] ?? "")")
        return try #require(reply["result"] as? [String: Any])
    }

    @Test func exportReturnsTheCommittedProgramOfTheSign() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let posted = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch"]))
        let text = try #require(posted["text"] as? String)
        let expected = try String(contentsOf: Self.root.appendingPathComponent("samples/expected/generic-grbl-inch/sign.nc"), encoding: .utf8)
        #expect(text == expected)
        #expect(posted["hasErrors"] as? Bool == false)
    }

    @Test func exportWritesThePostsBytes() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let file = AppTestSupport.tempDir().appendingPathComponent("out.tap")
        let posted = try Self.result(Self.call(s, "export", ["postID": "masso-g3-inch", "path": file.path]))
        #expect(posted["written"] as? String == file.path)
        let expected = try Data(contentsOf: Self.root.appendingPathComponent("samples/expected/masso-g3-inch/sign.nc"))
        #expect(try Data(contentsOf: file) == expected)
    }

    @Test func aProgramWithValidatorErrorsIsWrittenOnlyWithForce() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        // A cut deeper than the flutes is what the validator refuses.
        s.session.perform("Short flutes") { p in
            for i in p.tools.indices { p.tools[i].fluteLength = 0.01 }
        }
        let file = AppTestSupport.tempDir().appendingPathComponent("program.tap")
        let refused = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch", "path": file.path]))
        #expect(refused["hasErrors"] as? Bool == true)
        #expect(refused["written"] == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let forced = try Self.result(Self.call(s, "export", ["postID": "generic-grbl-inch", "path": file.path, "force": true]))
        #expect(forced["written"] as? String == file.path)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anUnknownPostIsAnError() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        #expect((try Self.call(s, "export", ["postID": "no-such-post"])["error"] as? String)?.contains("no-such-post") == true)
    }

    @Test func malformedInputGetsAnErrorReply() throws {
        let s = Self.service()
        for bad in ["", "not json", "{}", "{\"id\": 3}", "[1,2]"] {
            let reply = s.handle(Data(bad.utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any], "\(bad)")
            #expect(object["error"] is String, "\(bad)")
        }
        let unknown = try Self.call(s, "noSuchMethod", id: 9)
        #expect(unknown["id"] as? Int == 9)
        #expect((unknown["error"] as? String)?.contains("noSuchMethod") == true)
    }

    @Test func aFileThatIsNotAProjectIsAnErrorNotACrash() throws {
        let s = Self.service()
        let file = AppTestSupport.tempDir().appendingPathComponent("x.loftline")
        try Data("not a project".utf8).write(to: file)
        #expect(try Self.call(s, "open", ["path": file.path])["error"] is String)
        #expect(try Self.call(s, "open", ["path": "/no/such/file.loftline"])["error"] is String)
    }

    @Test func editsUndoAndRedo() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "new"))
        let added = try Self.result(Self.call(s, "addShape", ["tool": "rectangle", "from": ["x": 1, "y": 1], "to": ["x": 3, "y": 2]]))
        #expect(((added["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 1)
        #expect(added["isDirty"] as? Bool == true)
        #expect(added["undoAction"] as? String == "Add Rectangle")
        let undone = try Self.result(Self.call(s, "undo"))
        #expect(((undone["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 0)
        #expect(undone["isDirty"] as? Bool == false)
        let redone = try Self.result(Self.call(s, "redo"))
        #expect(((redone["project"] as? [String: Any])?["document"] as? [String: Any])?["shapes"].flatMap { ($0 as? [Any])?.count } == 1)
    }

    @Test func aToolpathGoesStaleWhenTheDesignMoves() throws {
        let s = Self.service()
        _ = try Self.result(Self.call(s, "open", ["path": Self.root.appendingPathComponent("samples/sign.loftline").path]))
        let calculated = try Self.result(Self.call(s, "calculate"))
        let before = try #require(calculated["statuses"] as? [[String: Any]])
        #expect(before.allSatisfy { $0["isStale"] as? Bool == false })
        let shapeID = s.session.project.document.shapes[0].id.uuidString
        let moved = try Self.result(Self.call(s, "translateShapes", ["ids": [shapeID], "by": ["x": 1, "y": 0]]))
        let after = try #require(moved["statuses"] as? [[String: Any]])
        #expect(after.allSatisfy { $0["isStale"] as? Bool == true })
    }
}
