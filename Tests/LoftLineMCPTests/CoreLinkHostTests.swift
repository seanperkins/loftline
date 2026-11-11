#if !os(Windows)
import CADCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// The desktop engine's end of the live link (spec 2, "The desktop host"): one window, run in place, one Undo step per edit,
/// a claim answered through standard input, stale front-end requests refused.
@Suite(.serialized) struct CoreLinkHostTests {
    struct Rig {
        let h = MCPHarness()
        let host: CoreLinkHost
        let server: LinkServer
        let settings: URL

        init() throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ch-\(UUID().uuidString.prefix(8))")
            settings = dir.appendingPathComponent("assistant.json")
            try AssistantSettings(allowedFolders: [h.allowed.path], liveLink: true).save(to: settings)
            h.service.assistantSettingsURL = settings
            host = CoreLinkHost(service: h.service, access: h.access, settingsFile: settings)
            server = LinkServer(folder: AssistantSettings.linkFolder(for: settings), host: host)
            host.server = server
            try server.start()
        }

        func stop() { server.stop(); try? FileManager.default.removeItem(at: settings.deletingLastPathComponent()) }

        /// A request as the desktop front end sends it, through the same lock as the stdin loop.
        func send(_ method: String, _ params: [String: Any] = [:], rev: Int? = nil) throws -> [String: Any] {
            var body: [String: Any] = ["id": 1, "method": method, "params": params]
            if let rev { body["rev"] = rev }
            let reply = host.handle(try JSONSerialization.data(withJSONObject: body))
            return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        }

        /// A claimed client, the user having clicked Allow through the front end.
        func claimed() throws -> LinkClient {
            let client = try LinkClient(socket: server.socketURL)
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            Thread.detachNewThread {
                do { try client.claim(CoreLinkHost.documentID) } catch { failure = error }
                done.signal()
            }
            for _ in 0..<400 {
                let status = try send("assistantStatus")["result"] as? [String: Any]
                if status?["asking"] as? Bool == true { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let start = Date()
            _ = try send("assistantAnswer", ["allow": true])
            #expect(done.wait(timeout: .now() + 2) == .success)
            #expect(Date().timeIntervalSince(start) < 1)
            if let failure { throw failure }
            return client
        }
    }

    @Test func claimAnsweredThroughStdinSucceeds() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let client = try rig.claimed()
        client.close()
    }

    @Test func editIsOneUndoStep() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try rig.claimed()
        defer { client.close() }
        _ = try client.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2],
                                                      ["type": "circle", "x": 6, "y": 6, "radius": 1]]])
        #expect(rig.h.session.project.document.shapes.count == 2)
        #expect(rig.h.session.undoAction == "Assistant: add_shapes")
        rig.h.session.undo()
        #expect(rig.h.session.project.document.shapes.isEmpty)
    }

    @Test func throwingEditLeavesSessionAndStacks() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        try rig.h.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        let before = (rig.h.session.project, rig.h.session.undoAction, rig.h.session.changeRevision)
        let client = try rig.claimed()
        defer { client.close() }
        #expect(throws: (any Error).self) { _ = try client.call("add_shapes", ["shapes": ["not an object"]]) }
        #expect(rig.h.session.project == before.0)
        #expect(rig.h.session.undoAction == before.1)
        #expect(rig.h.session.changeRevision == before.2)
    }

    @Test func inPlaceCalculateDoesNotDeadlock() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let client = try rig.claimed()
        defer { client.close() }
        let out = try client.call("calculate", [:])
        #expect(out.text.hasPrefix("Calculated"))
    }

    @Test func staleUpdateOperationIsRefusedAfterAToolpathOnlyEdit() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let seen = rig.h.session.changeRevision
        let op = try #require(rig.h.session.project.operations.first)
        let client = try rig.claimed()
        _ = try client.call("update_toolpath", ["id": op.id.uuidString, "enabled": !op.setup.isEnabled])
        client.close()
        let refused = try rig.send("undo", rev: seen)
        #expect((refused["code"] as? String) == "stale", "\(refused)")
        #expect(rig.h.session.undoAction == "Assistant: update_toolpath")
        let save = try rig.send("save", ["path": rig.h.allowed.appendingPathComponent("x.loftline").path], rev: seen)
        #expect((save["code"] as? String) == "stale")
        let current = try rig.send("undo", rev: rig.h.session.changeRevision)
        #expect(current["error"] == nil)
    }

    @Test func openWhileClaimedReleasesAndRevokes() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let client = try rig.claimed()
        defer { client.close() }
        _ = try rig.send("open", ["path": try rig.h.sample().path])
        #expect(throws: LinkClientError.self) { _ = try client.call("describe_project", [:]) }
        #expect(await rig.host.claims.allowed.isEmpty)
    }

    @Test func dialogOpenRefusesEdits() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try rig.claimed()
        defer { client.close() }
        _ = try rig.send("assistantDialog", ["open": true])
        #expect(throws: LinkClientError.self) {
            _ = try client.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        }
        #expect(rig.h.session.project.document.shapes.isEmpty)
        _ = try client.call("describe_project", [:])   // reads still work
        _ = try rig.send("assistantDialog", ["open": false])
        _ = try client.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        #expect(rig.h.session.project.document.shapes.count == 1)
    }

    @Test func saveAsWritesThroughAssistantWriter() throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try rig.claimed()
        defer { client.close() }
        let to = rig.h.allowed.appendingPathComponent("Saved.loftline")
        _ = try client.call("save_project", ["path": to.path])
        #expect(FileManager.default.fileExists(atPath: to.path))
        #expect(throws: LinkClientError.self) {
            _ = try client.call("save_project", ["path": rig.h.outside.appendingPathComponent("No.loftline").path])
        }
    }

    @Test func describeNamesTheDocumentAndPath() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let file = try rig.h.sample()
        try rig.h.call("open_project", ["path": file.path])
        let client = try rig.claimed()
        defer { client.close() }
        let text = try client.call("describe_project", [:]).text
        #expect(text.contains("\"document\"") && text.contains(file.lastPathComponent))
    }
}
#endif
