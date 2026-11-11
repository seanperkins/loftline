#if !os(Windows)
import Foundation
import Testing
@testable import LoftLineKit
@testable import LoftLineMCP

/// The server's document mode (spec 2, "The server"): list, claim, route every call to the window, and the refusals.
@Suite(.serialized) struct DocumentModeTests {
    struct Rig {
        let h = MCPHarness()
        let folder: URL
        let host: FakeHost
        let server: LinkServer
        let mode: DocumentMode
        let tools: [AssistantTool]

        init(docs: [LinkDocument] = [LinkDocument(id: "w1", name: "Sign", unsaved: false)], start: Bool = true) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("dm-\(UUID().uuidString.prefix(8))/link")
            host = FakeHost(docs: docs)
            server = LinkServer(folder: folder, host: host)
            if start { try server.start() }
            mode = DocumentMode(folder: folder)
            tools = AssistantTools.server(service: h.service, access: h.access, link: mode)
        }

        func stop() { mode.leave(); server.stop(); try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        func callNow(_ name: String, _ args: [String: Any] = [:]) throws -> ToolOutput {
            guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
            return try tool.call(args)
        }

        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> ToolOutput {
            try await offPool { try callNow(name, args) }
        }

        /// `use_open_document`, with the user clicking Allow.
        func use(_ document: String, id: String = "w1") async throws -> ToolOutput {
            let pending = Task { try await call("use_open_document", ["document": document]) }
            for _ in 0..<2000 where await !host.claims.asking.contains(id) { try await Task.sleep(for: .milliseconds(5)) }
            await host.claims.answer(id, allow: true)
            return try await pending.value
        }
    }

    @Test func listShowsNamesWithoutPaths() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let text = try await rig.call("list_open_documents").text
        #expect(text.contains("Sign") && text.contains("w1"))
        #expect(!text.contains(rig.folder.path))
    }

    @Test func nothingListeningNamesThePathTried() async throws {
        let rig = try Rig(start: false)
        defer { rig.stop() }
        let text = try await rig.call("list_open_documents").text
        #expect(text.contains(rig.server.socketURL.path))
    }

    @Test func useOpenDocumentRoutesLaterCalls() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        let out = try await rig.call("add_shapes", ["shapes": [] as [Any]])
        #expect(out.text == "ran add_shapes")
        #expect(rig.host.calls.map(\.tool) == ["add_shapes"])
        #expect(rig.h.session.project.document.shapes.isEmpty)
    }

    @Test func twoWindowsWithOneNameAreRefusedWithIDs() async throws {
        let rig = try Rig(docs: [LinkDocument(id: "a1", name: "Untitled", unsaved: true), LinkDocument(id: "b2", name: "Untitled", unsaved: true)])
        defer { rig.stop() }
        do {
            _ = try await rig.call("use_open_document", ["document": "Untitled"])
            Issue.record("expected a refusal")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            #expect(text.contains("a1") && text.contains("b2"), "\(text)")
        }
    }

    @Test func undoInDocumentModeSaysUndoIsYours() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        do {
            _ = try await rig.call("undo")
            Issue.record("expected a refusal")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == "Undo is yours: Edit ▸ Undo in LoftLine takes back the assistant's steps.")
        }
    }

    @Test func newProjectReturnsToFileMode() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        try await rig.call("new_project", ["units": "inch", "width": 12, "height": 8, "thickness": 0.5])
        try await rig.call("add_shapes", ["shapes": [["type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1]]])
        #expect(rig.h.session.project.document.shapes.count == 1)
        #expect(rig.host.calls.isEmpty)
    }

    @Test func secondUseClosesTheFirstConnection() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        #expect(await rig.host.claims.holder(of: "w1") != nil)
        let first = await rig.host.claims.holder(of: "w1")
        _ = try await rig.call("use_open_document", ["document": "w1"])   // already allowed: no question
        let second = await rig.host.claims.holder(of: "w1")
        #expect(second != nil && second != first)
    }

    @Test func closedLinkKeepsDocumentModeAndSaysWhy() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        rig.server.stop()
        for _ in 0..<2 {
            do {
                _ = try await rig.call("check")
                Issue.record("expected a refusal")
            } catch {
                #expect((error as? LocalizedError)?.errorDescription == "LoftLine closed the link (it quit, or its engine restarted); claim the document again.")
            }
        }
        #expect(rig.h.session.project.document.shapes.isEmpty)
    }

    @Test func releasedLinkSaysTheReason() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        rig.server.release(document: "w1", reason: "Sign closed.")
        do {
            _ = try await rig.call("check")
            Issue.record("expected a refusal")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == "Sign closed.")
        }
    }

    @Test func oversizeCallIsRefusedBeforeSending() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        _ = try await rig.use("Sign")
        rig.mode.maxRequest = 1000
        do {
            _ = try await rig.call("add_shapes", ["shapes": [["type": "polyline", "points": Array(repeating: ["x": 1, "y": 1], count: 200)]]])
            Issue.record("expected a refusal")
        } catch {}
        #expect(rig.host.calls.isEmpty)
        _ = try await rig.call("check")   // the claim survives
        #expect(rig.host.calls.map(\.tool) == ["check"])
    }
}
#endif
