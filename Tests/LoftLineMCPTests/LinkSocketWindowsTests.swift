#if os(Windows)
import Foundation
import Testing
@testable import LoftLineMCP

/// The spike the live link's Windows transport rests on (plan Task 1): an AF_UNIX socket from Swift, in a folder only the
/// user and SYSTEM can open, each end checking the other's account, a stale socket replaced, a non-ASCII path.
@Suite struct LinkSocketWindowsTests {
    @Test func windowsLinkRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-é-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("link")
        try LinkSocketWindows.makeFolder(folder)

        let me = try LinkSocketWindows.currentSID()
        let sddl = try LinkSocketWindows.folderSDDL(folder)
        #expect(sddl.contains("O:\(me)"), "\(sddl)")
        #expect(sddl.contains("D:P"), "\(sddl)")
        let aces = sddl.components(separatedBy: "(A;").count - 1
        #expect(aces == 2, "\(sddl)")
        #expect(sddl.contains(";;;\(me))") && sddl.contains(";;;SY)"), "\(sddl)")

        let socketURL = folder.appendingPathComponent("assistant.sock")
        let listener = try LinkSocketWindows.listen(at: socketURL)
        var serverPeer = ""
        let served = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { served.signal() }
            guard let conn = try? LinkSocketWindows.accept(listener) else { return }
            defer { LinkSocketWindows.close(conn) }
            serverPeer = (try? LinkSocketWindows.peerSID(of: conn)) ?? "error"
            if let line = try? LinkSocketWindows.receive(conn) { try? LinkSocketWindows.send(conn, line) }
        }
        let client = try LinkSocketWindows.connect(to: socketURL)
        let clientPeer = try LinkSocketWindows.peerSID(of: client)
        try LinkSocketWindows.send(client, Data("hello\n".utf8))
        let echoed = try LinkSocketWindows.receive(client)
        LinkSocketWindows.close(client)
        _ = served.wait(timeout: .now() + 10)
        #expect(String(decoding: echoed, as: UTF8.self) == "hello\n")
        #expect(clientPeer == me)
        #expect(serverPeer == me)

        LinkSocketWindows.close(listener)
        var refused = false
        do { _ = try LinkSocketWindows.connect(to: socketURL) } catch let e as LinkSocketWindows.Failure {
            refused = e.code == LinkSocketWindows.connectionRefused
            if !refused { Issue.record("connect after close: \(e.message)") }
        }
        #expect(refused)
        try LinkSocketWindows.removeStale(socketURL)
        let again = try LinkSocketWindows.listen(at: socketURL)
        LinkSocketWindows.close(again)
    }
}
#endif
