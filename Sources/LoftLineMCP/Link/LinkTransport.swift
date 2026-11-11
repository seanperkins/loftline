import Foundation
#if os(Windows)
import WinSDK
#endif

/// The link's socket calls on each platform, so the server and client are written once: the Unix socket on the Mac and Linux,
/// AF_UNIX through WinSDK on Windows.
enum LinkTransport {
    static func prepareFolder(_ url: URL) throws {
        #if os(Windows)
        try LinkSocketWindows.makeFolder(url)
        #else
        try LinkSocket.prepareFolder(url)
        #endif
    }

    static func listen(at url: URL) throws -> LinkHandle {
        #if os(Windows)
        if FileManager.default.fileExists(atPath: url.path) {
            if let live = try? LinkSocketWindows.connect(to: url) { LinkSocketWindows.close(live); throw LinkError.alreadyListening }
            try LinkSocketWindows.removeStale(url)
        }
        return try LinkSocketWindows.listen(at: url)
        #else
        return try LinkSocket.listen(at: url)
        #endif
    }

    static func connect(to url: URL) throws -> LinkHandle {
        #if os(Windows)
        let s = try LinkSocketWindows.connect(to: url)
        do { try checkPeer(s) } catch { LinkSocketWindows.close(s); throw error }
        return s
        #else
        return try LinkSocket.connect(to: url)
        #endif
    }

    static func accept(_ listener: LinkHandle) throws -> LinkHandle {
        #if os(Windows)
        try LinkSocketWindows.accept(listener)
        #else
        try LinkSocket.accept(listener)
        #endif
    }

    /// Refuses another user at the other end. On Windows systems that can't name the peer process (Server 2022), the link
    /// folder's access list is what keeps other users out.
    static func checkPeer(_ s: LinkHandle) throws {
        #if os(Windows)
        do {
            guard try LinkSocketWindows.peerSID(of: s) == LinkSocketWindows.currentSID() else { throw LinkError.wrongPeer }
        } catch let e as LinkSocketWindows.Failure where e.code == LinkSocketWindows.operationNotSupported {
            return
        }
        #else
        try LinkSocket.checkPeer(s)
        #endif
    }

    static func writeLine(_ s: LinkHandle, _ data: Data) throws {
        #if os(Windows)
        var bytes = data
        bytes.append(0x0A)
        try LinkSocketWindows.send(s, bytes)
        #else
        try LinkSocket.writeLine(s, data)
        #endif
    }

    static func close(_ s: LinkHandle) {
        #if os(Windows)
        LinkSocketWindows.close(s)
        #else
        LinkSocket.close(s)
        #endif
    }

    static func shutdown(_ s: LinkHandle) {
        #if os(Windows)
        _ = WinSDK.shutdown(s, Int32(SD_BOTH))
        #else
        LinkSocket.shutdown(s)
        #endif
    }

    static func setReceiveTimeout(_ s: LinkHandle, _ seconds: TimeInterval?) {
        #if os(Windows)
        var ms = DWORD((seconds ?? 0) * 1000)
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, withUnsafePointer(to: &ms) { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                       Int32(MemoryLayout<DWORD>.size))
        #else
        LinkSocket.setReceiveTimeout(s, seconds)
        #endif
    }
}
