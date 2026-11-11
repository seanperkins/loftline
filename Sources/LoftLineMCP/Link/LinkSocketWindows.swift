#if os(Windows)
import Foundation
import WinSDK

/// The live link's socket on Windows: an AF_UNIX socket (Windows 10 1803+) in a folder only the user and SYSTEM can open, with
/// each end checking the other's account (docs/superpowers/specs/2026-11-10-loftline-mcp-live-design.md, "The listener").
public typealias LinkHandle = SOCKET

public enum LinkSocketWindows {
    public struct Failure: LocalizedError {
        public var message: String
        public var code: Int32
        public var errorDescription: String? { message }
    }

    static let afUnix: Int32 = 1
    static let sockStream: Int32 = 1
    /// `_WSAIOR(IOC_VENDOR, 256)`: IOC_OUT | (sizeof(ULONG) << 16) | IOC_VENDOR | 256.
    static let sioAfUnixGetPeerPID: DWORD = 0x5804_0100
    static let connectionRefused: Int32 = 10061   // WSAECONNREFUSED

    /// `sockaddr_un` from afunix.h: an ADDRESS_FAMILY and 108 bytes of UTF-8 path.
    struct Address {
        var family: UInt16 = 1
        var path: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        init(_ url: URL) throws {
            let bytes = Array(url.path.utf8)
            guard bytes.count <= 107 else {
                throw Failure(message: "The link's path is too long (\(bytes.count) bytes): \(url.path)", code: 0)
            }
            withUnsafeMutableBytes(of: &path) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = b }
            }
        }
    }

    static var started = false
    static func startup() throws {
        if started { return }
        var data = WSADATA()
        let r = WSAStartup(0x0202, &data)
        guard r == 0 else { throw Failure(message: "Windows sockets didn't start (\(r)).", code: r) }
        started = true
    }

    static func lastError(_ what: String) -> Failure {
        let code = WSAGetLastError()
        return Failure(message: "\(what) failed (Windows sockets error \(code)).", code: code)
    }

    static func withAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, Int32) -> T) throws -> T {
        var address = try Address(url)
        return withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, Int32(MemoryLayout<Address>.size)) }
        }
    }

    /// Makes `url` (if missing) and gives it a protected DACL: owned by the current user, open only to that user and SYSTEM.
    public static func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let sid = try currentSID()
        let sddl = "O:\(sid)D:P(A;OICI;FA;;;\(sid))(A;OICI;FA;;;SY)"
        var descriptor: PSECURITY_DESCRIPTOR? = nil
        let made = sddl.withCString(encodedAs: UTF16.self) {
            ConvertStringSecurityDescriptorToSecurityDescriptorW($0, DWORD(SDDL_REVISION_1), &descriptor, nil)
        }
        guard made, let descriptor else {
            throw Failure(message: "Couldn't build the link folder's permissions (\(GetLastError())).", code: Int32(GetLastError()))
        }
        defer { LocalFree(descriptor) }
        let info = DWORD(OWNER_SECURITY_INFORMATION) | DWORD(DACL_SECURITY_INFORMATION) | DWORD(0x8000_0000)  // PROTECTED_DACL
        let set = url.path.withCString(encodedAs: UTF16.self) { SetFileSecurityW($0, info, descriptor) }
        guard set else {
            throw Failure(message: "Couldn't set the link folder's permissions (\(GetLastError())).", code: Int32(GetLastError()))
        }
    }

    /// The folder's owner and DACL as SDDL, so a test can check them.
    public static func folderSDDL(_ url: URL) throws -> String {
        let info = DWORD(OWNER_SECURITY_INFORMATION) | DWORD(DACL_SECURITY_INFORMATION)
        var needed: DWORD = 0
        _ = url.path.withCString(encodedAs: UTF16.self) { GetFileSecurityW($0, info, nil, 0, &needed) }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        let ok = buffer.withUnsafeMutableBytes { raw in
            url.path.withCString(encodedAs: UTF16.self) { GetFileSecurityW($0, info, raw.baseAddress, needed, &needed) }
        }
        guard ok else { throw Failure(message: "Couldn't read the link folder's permissions.", code: Int32(GetLastError())) }
        var text: LPWSTR? = nil
        let converted = buffer.withUnsafeMutableBytes { raw in
            ConvertSecurityDescriptorToStringSecurityDescriptorW(raw.baseAddress, DWORD(SDDL_REVISION_1), info, &text, nil)
        }
        guard converted, let text else { throw Failure(message: "Couldn't describe the link folder's permissions.", code: 0) }
        defer { LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
    }

    /// The folder's owner, whether its DACL is protected, and the SIDs its allow entries name, read through the SID API rather
    /// than SDDL text (which writes well-known accounts as aliases such as LA or SY).
    public static func folderAccess(_ url: URL) throws -> (owner: String, protected: Bool, allowed: [String]) {
        let info = DWORD(OWNER_SECURITY_INFORMATION) | DWORD(DACL_SECURITY_INFORMATION)
        var needed: DWORD = 0
        _ = url.path.withCString(encodedAs: UTF16.self) { GetFileSecurityW($0, info, nil, 0, &needed) }
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        return try buffer.withUnsafeMutableBytes { raw in
            let sd = raw.baseAddress
            guard url.path.withCString(encodedAs: UTF16.self, { GetFileSecurityW($0, info, sd, needed, &needed) }) else {
                throw Failure(message: "Couldn't read the link folder's permissions.", code: Int32(GetLastError()))
            }
            var ownerSID: PSID? = nil
            var defaulted: WindowsBool = false
            guard GetSecurityDescriptorOwner(sd, &ownerSID, &defaulted), let ownerSID else {
                throw Failure(message: "The link folder has no owner.", code: 0)
            }
            var control: SECURITY_DESCRIPTOR_CONTROL = 0
            var revision: DWORD = 0
            _ = GetSecurityDescriptorControl(sd, &control, &revision)
            var present: WindowsBool = false
            var acl: PACL? = nil
            guard GetSecurityDescriptorDacl(sd, &present, &acl, &defaulted), present.boolValue, let acl else {
                throw Failure(message: "The link folder has no access list.", code: 0)
            }
            var allowed: [String] = []
            for i in 0..<DWORD(acl.pointee.AceCount) {
                var ace: LPVOID? = nil
                guard GetAce(acl, i, &ace), let ace else { continue }
                let header = ace.assumingMemoryBound(to: ACE_HEADER.self).pointee
                guard header.AceType == 0 else { continue }   // ACCESS_ALLOWED_ACE_TYPE
                // ACCESS_ALLOWED_ACE: ACE_HEADER, ACCESS_MASK, then the SID.
                let sid = UnsafeMutableRawPointer(ace).advanced(by: MemoryLayout<ACE_HEADER>.size + MemoryLayout<DWORD>.size)
                allowed.append(try sidString(sid))
            }
            return (try sidString(ownerSID), (control & 0x1000) != 0, allowed)   // SE_DACL_PROTECTED
        }
    }

    static func sidString(_ sid: PSID) throws -> String {
        var text: LPWSTR? = nil
        guard ConvertSidToStringSidW(sid, &text), let text else { throw Failure(message: "Couldn't describe an account.", code: 0) }
        defer { LocalFree(text) }
        return String(decodingCString: text, as: UTF16.self)
    }

    /// Whether the system answers `SIO_AF_UNIX_GETPEERPID` (Windows Server 2022 doesn't: WSAEOPNOTSUPP).
    public static let operationNotSupported: Int32 = 10045

    public static func listen(at url: URL) throws -> LinkHandle {
        try startup()
        let s = socket(afUnix, sockStream, 0)
        guard s != INVALID_SOCKET else { throw lastError("Making the link socket") }
        let bound = try withAddress(url) { bind(s, $0, $1) }
        guard bound == 0 else { let e = lastError("Binding \(url.path)"); closesocket(s); throw e }
        guard WinSDK.listen(s, 4) == 0 else { let e = lastError("Listening"); closesocket(s); throw e }
        return s
    }

    public static func connect(to url: URL) throws -> LinkHandle {
        try startup()
        let s = socket(afUnix, sockStream, 0)
        guard s != INVALID_SOCKET else { throw lastError("Making the link socket") }
        let r = try withAddress(url) { WinSDK.connect(s, $0, $1) }
        guard r == 0 else { let e = lastError("Connecting to \(url.path)"); closesocket(s); throw e }
        return s
    }

    public static func accept(_ listener: LinkHandle) throws -> LinkHandle {
        let s = WinSDK.accept(listener, nil, nil)
        guard s != INVALID_SOCKET else { throw lastError("Accepting a link connection") }
        return s
    }

    public static func close(_ s: LinkHandle) { closesocket(s) }

    public static func send(_ s: LinkHandle, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw -> Int32 in
                let p = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self)
                return WinSDK.send(s, p, Int32(min(data.count - offset, 1 << 20)), 0)
            }
            guard n > 0 else { throw lastError("Sending on the link") }
            offset += Int(n)
        }
    }

    /// Up to `max` bytes, or empty at the end of the stream.
    public static func receive(_ s: LinkHandle, max: Int = 65536) throws -> Data {
        var buffer = [CChar](repeating: 0, count: max)
        let n = recv(s, &buffer, Int32(max), 0)
        guard n >= 0 else { throw lastError("Reading the link") }
        return Data(buffer[0..<Int(n)].map { UInt8(bitPattern: $0) })
    }

    /// Removes a socket file nothing listens on.
    public static func removeStale(_ url: URL) throws {
        let removed = url.path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        guard removed else { throw Failure(message: "Couldn't remove \(url.path) (\(GetLastError())).", code: Int32(GetLastError())) }
    }

    /// The account (SID as text) of the process at the other end of a connected socket.
    public static func peerSID(of s: LinkHandle) throws -> String {
        var pid: ULONG = 0
        var returned: DWORD = 0
        let r = WSAIoctl(s, sioAfUnixGetPeerPID, nil, 0, &pid, DWORD(MemoryLayout<ULONG>.size), &returned, nil, nil)
        guard r == 0 else { throw lastError("Asking who is at the other end of the link") }
        guard let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid)) else {
            throw Failure(message: "Couldn't open the process at the other end of the link (\(GetLastError())).", code: Int32(GetLastError()))
        }
        defer { CloseHandle(process) }
        return try sid(ofProcess: process)
    }

    /// The current user's SID as text.
    public static func currentSID() throws -> String { try sid(ofProcess: GetCurrentProcess()) }

    static func sid(ofProcess process: HANDLE) throws -> String {
        var token: HANDLE? = nil
        guard OpenProcessToken(process, DWORD(TOKEN_QUERY), &token), let token else {
            throw Failure(message: "Couldn't read a process's account (\(GetLastError())).", code: Int32(GetLastError()))
        }
        defer { CloseHandle(token) }
        var needed: DWORD = 0
        _ = GetTokenInformation(token, TokenUser, nil, 0, &needed)
        var buffer = [UInt8](repeating: 0, count: Int(needed))
        return try buffer.withUnsafeMutableBytes { raw -> String in
            guard GetTokenInformation(token, TokenUser, raw.baseAddress, needed, &needed) else {
                throw Failure(message: "Couldn't read a process's account (\(GetLastError())).", code: Int32(GetLastError()))
            }
            let user = raw.baseAddress!.assumingMemoryBound(to: TOKEN_USER.self).pointee
            var text: LPWSTR? = nil
            guard ConvertSidToStringSidW(user.User.Sid, &text), let text else {
                throw Failure(message: "Couldn't describe a process's account.", code: Int32(GetLastError()))
            }
            defer { LocalFree(text) }
            return String(decodingCString: text, as: UTF16.self)
        }
    }
}
#endif
