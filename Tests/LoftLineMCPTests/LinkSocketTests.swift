#if !os(Windows)
import Foundation
import Testing
@testable import LoftLineMCP

/// The live link's Unix socket (spec 2, "The listener"): a private folder, a byte limit on the path, a live socket never
/// unlinked, a stale one replaced, the peer's uid checked, lines framed with a cap.
@Suite struct LinkSocketTests {
    /// A short folder in the system's temporary folder (sandboxes allow sockets there), so paths stay under the 103-byte limit.
    static func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ll-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func prepareFolderMakesAPrivateFolder() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("link")
        try LinkSocket.prepareFolder(folder)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        try LinkSocket.prepareFolder(folder)   // a second time is fine
    }

    @Test func folderMustBePrivate() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let open = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(throws: LinkError.self) { try LinkSocket.prepareFolder(open) }
        let real = root.appendingPathComponent("real")
        try LinkSocket.prepareFolder(real)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: LinkError.self) { try LinkSocket.prepareFolder(link) }
    }

    @Test func pathOver103BytesIsRefused() throws {
        // 40 two-byte characters: 80 bytes of name, so the path is well over 103 bytes while under 103 characters.
        let name = String(repeating: "é", count: 40)
        let url = URL(fileURLWithPath: "/tmp/\(name)/assistant.sock")
        #expect(url.path.count < 103 && url.path.utf8.count > 103)
        #expect(throws: LinkError.self) { _ = try LinkSocket.listen(at: url) }
    }

    @Test func roundTripAndPeerCheck() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sock = root.appendingPathComponent("assistant.sock")
        let listener = try LinkSocket.listen(at: sock)
        defer { LinkSocket.close(listener) }
        let served = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { served.signal() }
            guard let conn = try? LinkSocket.accept(listener) else { return }
            defer { LinkSocket.close(conn) }
            try? LinkSocket.checkPeer(conn)
            let reader = LinkReader(conn, max: 1024)
            if case .line(let data)? = try? reader.next() { try? LinkSocket.writeLine(conn, data) }
        }
        let client = try LinkSocket.connect(to: sock)
        defer { LinkSocket.close(client) }
        try LinkSocket.writeLine(client, Data("hello".utf8))
        let reply = try LinkReader(client, max: 1024).next()
        _ = served.wait(timeout: .now() + 5)
        #expect(reply == .line(Data("hello".utf8)))
    }

    @Test func peerWithAnotherUIDIsRefused() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sock = root.appendingPathComponent("assistant.sock")
        let listener = try LinkSocket.listen(at: sock)
        defer { LinkSocket.close(listener) }
        #expect(throws: LinkError.wrongPeer) {
            _ = try LinkSocket.connect(to: sock, peerUID: { _ in getuid() + 1 })
        }
    }

    @Test func liveSocketIsNotUnlinked() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sock = root.appendingPathComponent("assistant.sock")
        let listener = try LinkSocket.listen(at: sock)
        defer { LinkSocket.close(listener) }
        #expect(throws: LinkError.alreadyListening) { _ = try LinkSocket.listen(at: sock) }
        let client = try LinkSocket.connect(to: sock)
        LinkSocket.close(client)
    }

    @Test func staleSocketIsReplaced() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sock = root.appendingPathComponent("assistant.sock")
        let first = try LinkSocket.listen(at: sock)
        LinkSocket.close(first)   // the file stays, as after a crash
        #expect(FileManager.default.fileExists(atPath: sock.path))
        let second = try LinkSocket.listen(at: sock)
        LinkSocket.close(second)
    }

    @Test func readerReportsAnOversizeLineAndCarriesOn() throws {
        let pair = try LinkSocket.pair()
        let fds = [pair.0, pair.1]
        defer { LinkSocket.close(fds[0]) }
        try LinkSocket.writeLine(fds[1], Data(repeating: 0x61, count: 2000))
        try LinkSocket.writeLine(fds[1], Data("ok".utf8))
        let reader = LinkReader(fds[0], max: 1000)
        #expect(try reader.next() == .tooLong)
        #expect(try reader.next() == .line(Data("ok".utf8)))
        LinkSocket.close(fds[1])
        #expect(try reader.next() == nil)
    }
}

#endif
