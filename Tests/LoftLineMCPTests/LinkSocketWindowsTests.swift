#if os(Windows)
import Foundation
import Testing
@testable import LoftLineMCP

/// The spike the live link's Windows transport rests on (plan Task 1): an AF_UNIX socket from Swift, in a folder only the
/// user and SYSTEM can open, each end checking the other's account where the system can say, a stale socket replaced, a
/// non-ASCII path.
@Suite struct LinkSocketWindowsTests {
    final class Box: @unchecked Sendable { var value = "" }

    @Test func windowsLinkRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-é-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("link")
        try LinkSocketWindows.makeFolder(folder)

        let me = try LinkSocketWindows.currentSID()
        let access = try LinkSocketWindows.folderAccess(folder)
        print("spike: me=\(me) owner=\(access.owner) protected=\(access.protected) allowed=\(access.allowed) sddl=\(try LinkSocketWindows.folderSDDL(folder))")
        #expect(access.owner == me)
        #expect(access.protected)
        #expect(Set(access.allowed) == [me, "S-1-5-18"], "\(access.allowed)")

        let socketURL = folder.appendingPathComponent("assistant.sock")
        let listener = try LinkSocketWindows.listen(at: socketURL)
        let serverPeer = Box()
        let served = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { served.signal() }
            guard let conn = try? LinkSocketWindows.accept(listener) else { return }
            defer { LinkSocketWindows.close(conn) }
            do { serverPeer.value = try LinkSocketWindows.peerSID(of: conn) } catch let e as LinkSocketWindows.Failure {
                serverPeer.value = "error \(e.code)"
            } catch { serverPeer.value = "error" }
            if let line = try? LinkSocketWindows.receive(conn) { try? LinkSocketWindows.send(conn, line) }
        }
        let client = try LinkSocketWindows.connect(to: socketURL)
        var clientPeer = ""
        do { clientPeer = try LinkSocketWindows.peerSID(of: client) } catch let e as LinkSocketWindows.Failure { clientPeer = "error \(e.code)" }
        try LinkSocketWindows.send(client, Data("hello\n".utf8))
        let echoed = try LinkSocketWindows.receive(client)
        LinkSocketWindows.close(client)
        _ = served.wait(timeout: .now() + 10)
        print("spike: clientPeer=\(clientPeer) serverPeer=\(serverPeer.value)")
        #expect(String(decoding: echoed, as: UTF8.self) == "hello\n")
        let unsupported = "error \(LinkSocketWindows.operationNotSupported)"
        #expect(clientPeer == me || clientPeer == unsupported)
        #expect(serverPeer.value == me || serverPeer.value == unsupported)

        LinkSocketWindows.close(listener)
        var refused = false
        do { _ = try LinkSocketWindows.connect(to: socketURL) } catch let e as LinkSocketWindows.Failure {
            refused = e.code == LinkSocketWindows.connectionRefused
            print("spike: connect after close: \(e.code)")
        }
        #expect(refused)
        try LinkSocketWindows.removeStale(socketURL)
        let again = try LinkSocketWindows.listen(at: socketURL)
        LinkSocketWindows.close(again)
        print("spike: stale socket replaced")
    }
}
#endif
