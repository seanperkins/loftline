#if !os(Windows)
import Foundation
import Testing
@testable import LoftLineMCP

/// A host with one window, "Sign", that records the calls it gets.
final class FakeHost: LinkHost, @unchecked Sendable {
    let claims: ClaimBook
    private let lock = NSLock()
    private var _calls: [LinkCall] = []
    var calls: [LinkCall] { lock.lock(); defer { lock.unlock() }; return _calls }

    let docs: [LinkDocument]

    init(timeout: Duration = .seconds(5), docs: [LinkDocument] = [LinkDocument(id: "w1", name: "Sign", unsaved: false)]) {
        claims = ClaimBook(timeout: timeout) { }
        self.docs = docs
    }

    func documents() -> [LinkDocument] { docs }

    func run(_ call: LinkCall) async throws -> ToolOutput {
        lock.lock(); _calls.append(call); lock.unlock()
        return ToolOutput(text: "ran \(call.tool)", image: call.tool == "preview" ? Data([1, 2, 3]) : nil)
    }
}

/// The link's protocol over a real socket (spec 2, "The link protocol").
@Suite(.serialized) struct LinkServerTests {
    struct Rig {
        let folder: URL
        let host: FakeHost
        let server: LinkServer

        init(idle: TimeInterval = 30, maxRequest: Int = 64 << 20, timeout: Duration = .seconds(5)) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ls-\(UUID().uuidString.prefix(8))/link")
            host = FakeHost(timeout: timeout)
            server = LinkServer(folder: folder, host: host, idleTimeout: idle, maxRequest: maxRequest)
            try server.start()
        }

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }

        func connect() throws -> Conn { Conn(fd: try LinkSocket.connect(to: server.socketURL)) }

        /// A connection holding the window, the user having clicked Allow.
        func claimed() async throws -> Conn {
            let c = try connect()
            try c.send(["v": 1, "op": "claim", "document": "w1"])
            for _ in 0..<2000 where await !host.claims.asking.contains("w1") { try await Task.sleep(for: .milliseconds(5)) }
            await host.claims.answer("w1", allow: true)
            let reply = try c.receive()
            #expect(reply?["error"] == nil, "\(String(describing: reply))")
            return c
        }
    }

    struct Conn {
        let fd: LinkHandle
        let reader: LinkReader
        init(fd: LinkHandle) { self.fd = fd; reader = LinkReader(fd, max: 64 << 20) }
        func send(_ object: [String: Any]) throws { try LinkSocket.writeLine(fd, try JSONSerialization.data(withJSONObject: object)) }
        func sendRaw(_ text: String) throws { try LinkSocket.writeLine(fd, Data(text.utf8)) }
        func receive() throws -> [String: Any]? {
            guard case .line(let data)? = try reader.next() else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func errorCode(_ reply: [String: Any]?) -> String? { (reply?["error"] as? [String: Any])?["code"] as? String }
        func errorMessage(_ reply: [String: Any]?) -> String? { (reply?["error"] as? [String: Any])?["message"] as? String }
        func close() { LinkSocket.close(fd) }
    }

    @Test func listAnswersThenCloses() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        try c.send(["v": 1, "op": "list"])
        let reply = try c.receive()
        let docs = try #require(reply?["documents"] as? [[String: Any]])
        #expect(docs.count == 1 && docs[0]["name"] as? String == "Sign" && docs[0]["path"] == nil)
        #expect(docs[0]["claimed"] as? Bool == false)
        #expect(try c.receive() == nil)
    }

    @Test func claimThenCallReachesTheHostWithItsKind() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try await rig.claimed()
        defer { c.close() }
        try c.send(["v": 1, "op": "call", "tool": "add_shapes", "arguments": ["shapes": [] as [Any]]])
        let reply = try c.receive()
        #expect(reply?["text"] as? String == "ran add_shapes")
        let call = try #require(rig.host.calls.first)
        #expect(call.kind == .edit && call.document == "w1")
        try c.send(["v": 1, "op": "call", "tool": "preview", "arguments": [String: Any]()])
        #expect(try c.receive()?["image"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func aCallWithoutAClaimIsRefused() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        try c.send(["v": 1, "op": "call", "tool": "check", "arguments": [String: Any]()])
        #expect(c.errorCode(try c.receive()) == "not_claimed")
        #expect(rig.host.calls.isEmpty)
    }

    @Test func neverAndUnknownToolsAreRefusedBeforeTheHost() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try await rig.claimed()
        defer { c.close() }
        for tool in ["new_project", "open_project", "undo", "rm_rf"] {
            try c.send(["v": 1, "op": "call", "tool": tool, "arguments": [String: Any]()])
            #expect(c.errorCode(try c.receive()) == "refused", "\(tool)")
        }
        #expect(rig.host.calls.isEmpty)
    }

    @Test func versionMismatchNamesTheOlderSide() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        try c.send(["v": 2, "op": "list"])
        #expect(c.errorMessage(try c.receive()) == "This LoftLine is older than its assistant server; update LoftLine.")
        try c.send(["v": 0, "op": "list"])
        #expect(c.errorMessage(try c.receive())
                == "The assistant server is older than this LoftLine; point the assistant at the server inside this LoftLine.")
    }

    @Test func fifthConnectionIsRefused() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let four = try (0..<4).map { _ in try rig.connect() }
        defer { four.forEach { $0.close() } }
        Thread.sleep(forTimeInterval: 0.1)
        let fifth = try rig.connect()
        defer { fifth.close() }
        #expect(fifth.errorCode(try fifth.receive()) == "busy")
        #expect(try fifth.receive() == nil)
    }

    @Test func idleUnclaimedConnectionCloses() throws {
        let rig = try Rig(idle: 0.2)
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        #expect(try c.receive() == nil)
    }

    @Test func oversizeRequestGetsAnErrorAndKeepsTheConnection() throws {
        let rig = try Rig(maxRequest: 1000)
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        try c.sendRaw(String(repeating: "a", count: 2000))
        #expect(c.errorCode(try c.receive()) == "too_large")
        try c.send(["v": 1, "op": "list"])
        #expect(try c.receive()?["documents"] != nil)
    }

    @Test func nonObjectLineCloses() throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try rig.connect()
        defer { c.close() }
        try c.sendRaw("[1,2]")
        #expect(try c.receive() == nil)
    }

    @Test func newlineInsideArgumentsIsOneRequest() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try await rig.claimed()
        defer { c.close() }
        let sneaky = "a\n{\"v\":1,\"op\":\"call\",\"tool\":\"post_gcode\",\"arguments\":{}}"
        try c.send(["v": 1, "op": "call", "tool": "check", "arguments": ["note": sneaky]])
        _ = try c.receive()
        #expect(rig.host.calls.map(\.tool) == ["check"])
        #expect(rig.host.calls.first?.arguments["note"] as? String == sneaky)
    }

    @Test func releaseSendsReleasedWithTheReason() async throws {
        let rig = try Rig()
        defer { rig.stop() }
        let c = try await rig.claimed()
        defer { c.close() }
        rig.server.release(document: "w1", reason: "the window closed")
        let reply = try c.receive()
        #expect(c.errorCode(reply) == "released" && c.errorMessage(reply) == "the window closed")
        #expect(try c.receive() == nil)
    }
}
#endif
