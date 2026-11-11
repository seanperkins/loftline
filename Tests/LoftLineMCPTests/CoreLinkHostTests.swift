#if !os(Windows)
import CADCore
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// The desktop engine's end of the live link (spec 2, "The desktop host"): one window, run in place, one Undo step per edit,
/// a claim answered through standard input, stale front-end requests refused.
@Suite(.serialized) struct CoreLinkHostTests {
    /// A link call made off the cooperative pool.
    func call(_ client: LinkClient, _ tool: String, _ arguments: [String: Any]) async throws -> ToolOutput {
        try await offPool { try client.call(tool, arguments) }
    }

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
        func claimed() async throws -> LinkClient { try await offPool { try claimedNow() } }

        func claimedNow() throws -> LinkClient {
            let client = try LinkClient(socket: server.socketURL)
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            Thread.detachNewThread {
                do { try client.claim(CoreLinkHost.documentID) } catch { failure = error }
                done.signal()
            }
            for _ in 0..<2000 {
                let status = try send("assistantStatus")["result"] as? [String: Any]
                if status?["asking"] as? Bool == true { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            let start = Date()
            _ = try send("assistantAnswer", ["allow": true])
            #expect(done.wait(timeout: .now() + 10) == .success)
            #expect(Date().timeIntervalSince(start) < 10)
            if let failure { throw failure }
            return client
        }
    }

    @Test func claimAnsweredThroughStdinSucceeds() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let client = try await rig.claimed()
        client.close()
    }

    @Test func editIsOneUndoStep() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try await rig.claimed()
        defer { client.close() }
        _ = try await call(client, "add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2],
                                                      ["type": "circle", "x": 6, "y": 6, "radius": 1]]])
        #expect(rig.h.session.project.document.shapes.count == 2)
        #expect(rig.h.session.undoAction == "Assistant: add_shapes")
        rig.h.session.undo()
        #expect(rig.h.session.project.document.shapes.isEmpty)
    }

    @Test func throwingEditLeavesSessionAndStacks() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        try rig.h.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        let before = (rig.h.session.project, rig.h.session.undoAction, rig.h.session.changeRevision)
        let client = try await rig.claimed()
        defer { client.close() }
        await #expect(throws: (any Error).self) { _ = try await call(client, "add_shapes", ["shapes": ["not an object"]]) }
        #expect(rig.h.session.project == before.0)
        #expect(rig.h.session.undoAction == before.1)
        #expect(rig.h.session.changeRevision == before.2)
    }

    @Test func inPlaceCalculateDoesNotDeadlock() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let client = try await rig.claimed()
        defer { client.close() }
        let out = try await call(client, "calculate", [:])
        #expect(out.text.hasPrefix("Calculated"))
    }

    @Test func staleUpdateOperationIsRefusedAfterAToolpathOnlyEdit() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let seen = rig.h.session.changeRevision
        let op = try #require(rig.h.session.project.operations.first)
        let client = try await rig.claimed()
        _ = try await call(client, "update_toolpath", ["id": op.id.uuidString, "enabled": !op.setup.isEnabled])
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
        let client = try await rig.claimed()
        defer { client.close() }
        _ = try rig.send("open", ["path": try rig.h.sample().path])
        await #expect(throws: LinkClientError.self) { _ = try await call(client, "describe_project", [:]) }
        #expect(await rig.host.claims.allowed.isEmpty)
    }

    @Test func dialogOpenRefusesEdits() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try await rig.claimed()
        defer { client.close() }
        _ = try rig.send("assistantDialog", ["open": true])
        await #expect(throws: LinkClientError.self) {
            _ = try await call(client, "add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        }
        #expect(rig.h.session.project.document.shapes.isEmpty)
        _ = try await call(client, "describe_project", [:])   // reads still work
        _ = try rig.send("assistantDialog", ["open": false])
        _ = try await call(client, "add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 2, "height": 2]]])
        #expect(rig.h.session.project.document.shapes.count == 1)
    }

    @Test func saveAsWritesThroughAssistantWriter() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try await rig.claimed()
        defer { client.close() }
        let to = rig.h.allowed.appendingPathComponent("Saved.loftline")
        _ = try await call(client, "save_project", ["path": to.path])
        #expect(FileManager.default.fileExists(atPath: to.path))
        await #expect(throws: LinkClientError.self) {
            _ = try await call(client, "save_project", ["path": rig.h.outside.appendingPathComponent("No.loftline").path])
        }
    }

    @Test func describeNamesTheDocumentAndPath() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let file = try rig.h.sample()
        try rig.h.call("open_project", ["path": file.path])
        let client = try await rig.claimed()
        defer { client.close() }
        let text = try await call(client, "describe_project", [:]).text
        #expect(text.contains("\"document\"") && text.contains(file.lastPathComponent))
    }

    @Test func coreMarkerSurvivesAssistantAndUserSave() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let file = try rig.h.sample()
        try rig.h.call("open_project", ["path": file.path])
        let client = try await rig.claimed()
        defer { client.close() }
        func changes() throws -> Int? { (try rig.send("assistantStatus")["result"] as? [String: Any])?["changes"] as? Int }
        _ = try await call(client, "add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1]]])
        #expect(try changes() == 1)
        _ = try await call(client, "save_project", [:])
        #expect(try changes() == 1)
        _ = try rig.send("save", ["path": file.path], rev: rig.h.session.changeRevision)
        #expect(try changes() == 1)
        let report = try #require(try rig.send("checkReport")["result"] as? [String: Any])
        let messages = (report["sections"] as? [[String: Any]] ?? []).flatMap { ($0["issues"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["message"] as? String }
        #expect(messages.contains("Changed by an assistant (1 change)"), "\(messages)")
        // A new store reads the same record: it is on disk, keyed by the file.
        #expect(ReviewMarkerStore(file: rig.settings.deletingLastPathComponent().appendingPathComponent("review.json")).count(for: file) == 1)
        _ = try rig.send("dismissAssistantMarker")
        #expect(try changes() == 0)
    }

    @Test func untitledCountReachesTheRecordOnItsFirstSave() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try await rig.claimed()
        defer { client.close() }
        _ = try await call(client, "add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1]]])
        let to = rig.h.allowed.appendingPathComponent("New.loftline")
        _ = try await call(client, "save_project", ["path": to.path])
        #expect(ReviewMarkerStore(file: rig.settings.deletingLastPathComponent().appendingPathComponent("review.json")).count(for: to) == 1)
    }

    // Final review fixes (debate 98aaaac4).

    @Test func aCalculationDoesNotMakeTheNextEditStale() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let seen = rig.h.session.changeRevision
        _ = try rig.send("calculate", [:])
        #expect(rig.h.session.changeRevision == seen)
        let op = try #require(rig.h.session.project.operations.first)
        let reply = try rig.send("deleteOperation", ["id": op.id.uuidString], rev: seen)
        #expect(reply["code"] == nil, "\(reply)")
    }

    @Test func anAssistantCalculationMovesTheStatusTheWindowPolls() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("open_project", ["path": try rig.h.sample().path])
        let client = try await rig.claimed()
        defer { client.close() }
        func revision() throws -> Int? { (try rig.send("assistantStatus")["result"] as? [String: Any])?["assistantRevision"] as? Int }
        let before = try revision()
        _ = try await call(client, "calculate", [:])
        #expect(try revision() != before)
    }

    @Test func aCallQueuedBehindAnOpenIsRefused() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        try rig.h.call("new_project", ["units": "inch", "width": 24, "height": 18, "thickness": 0.75])
        let client = try await rig.claimed()
        defer { client.close() }
        let generation = rig.host.generation(of: CoreLinkHost.documentID)
        _ = try rig.send("open", ["path": try rig.h.sample().path])
        let shapes = rig.h.session.project.document.shapes.count
        let late = LinkCall(kind: .edit, tool: "add_shapes", arguments: ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1]]],
                            document: CoreLinkHost.documentID, generation: generation)
        await #expect(throws: (any Error).self) { _ = try await rig.host.run(late) }
        #expect(rig.h.session.project.document.shapes.count == shapes)
    }

    @Test func aSwitchThatCannotListenStaysOff() throws {
        let h = MCPHarness()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent("assistant.json")
        try AssistantSettings(allowedFolders: [h.allowed.path]).save(to: settings)
        try FileManager.default.createDirectory(at: AssistantSettings.linkFolder(for: settings), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        h.service.assistantSettingsURL = settings
        let host = CoreLinkHost(service: h.service, access: h.access, settingsFile: settings)
        let line = try JSONSerialization.data(withJSONObject: ["id": 1, "method": "setAssistantLink", "params": ["on": true]])
        let reply = try #require(try JSONSerialization.jsonObject(with: host.handle(line)) as? [String: Any])
        #expect(reply["error"] != nil, "\(reply)")
        #expect(AssistantSettings.load(from: settings).liveLink == false)
    }
}
#endif
