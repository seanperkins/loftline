import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What can go wrong setting up or using the live link's socket, in the words the switch and the assistant show (spec 2,
/// "The listener").
public enum LinkError: Error, LocalizedError, Equatable {
    case tooLong(String)
    case notPrivate(String)
    case alreadyListening
    case wrongPeer
    case system(String)

    public var errorDescription: String? {
        switch self {
        case .tooLong(let path): return "The link's path is longer than 103 bytes: \(path)"
        case .notPrivate(let path): return "\(path) must be a folder only you can open (mode 0700)."
        case .alreadyListening: return "Another LoftLine is already listening."
        case .wrongPeer: return "The other end of the link belongs to another user."
        case .system(let text): return text
        }
    }
}

#if !os(Windows)
public typealias LinkHandle = Int32

/// The live link's Unix socket on the Mac and Linux: a folder only the user can open, a path no longer than 103 bytes, a socket
/// a crash left behind replaced but a live one never unlinked, and the uid at the other end checked on the connected socket.
public enum LinkSocket {
    public static let maxPathBytes = 103

    static func failure(_ what: String) -> LinkError { .system("\(what) failed: \(String(cString: strerror(errno))).") }

    #if canImport(Glibc)
    static let stream = Int32(SOCK_STREAM.rawValue)
    #else
    static let stream = SOCK_STREAM
    #endif

    /// Makes `url` a folder only the user can open, or checks that it already is one: a real directory (not a link), owned by
    /// this user, mode 0700.
    public static func prepareFolder(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("Checking \(url.path)") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw failure("Making \(url.path)") }
            guard lstat(url.path, &info) == 0 else { throw failure("Checking \(url.path)") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw LinkError.notPrivate(url.path)
        }
    }

    static func withAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(url.path.utf8)
        guard bytes.count <= maxPathBytes else { throw LinkError.tooLong(url.path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        return withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Listens at `url`. A socket file another LoftLine still answers on is left alone; one nothing answers on is replaced.
    public static func listen(at url: URL) throws -> LinkHandle {
        guard url.path.utf8.count <= maxPathBytes else { throw LinkError.tooLong(url.path) }
        if let live = try? rawConnect(url) {
            close(live)
            throw LinkError.alreadyListening
        }
        if FileManager.default.fileExists(atPath: url.path) { unlink(url.path) }
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { throw failure("Making the link socket") }
        let old = umask(0o077)
        let bound = try withAddress(url) { bind(fd, $0, $1) }
        umask(old)
        guard bound == 0 else { let e = failure("Binding \(url.path)"); close(fd); throw e }
        guard Glibc_or_Darwin_listen(fd, 4) == 0 else { let e = failure("Listening"); close(fd); throw e }
        return fd
    }

    static func rawConnect(_ url: URL) throws -> LinkHandle {
        let fd = socket(AF_UNIX, stream, 0)
        guard fd >= 0 else { throw failure("Making the link socket") }
        let r = try withAddress(url) { Glibc_or_Darwin_connect(fd, $0, $1) }
        guard r == 0 else { let e = failure("Connecting to \(url.path)"); close(fd); throw e }
        return fd
    }

    /// Connects to LoftLine at `url` and checks the other end runs as this user. `peerUID` is a seam for tests.
    public static func connect(to url: URL, peerUID: (LinkHandle) throws -> uid_t = LinkSocket.peerUID) throws -> LinkHandle {
        var info = stat()
        if stat(url.path, &info) == 0, info.st_uid != getuid() { throw LinkError.wrongPeer }
        let fd = try rawConnect(url)
        do { try checkPeer(fd, peerUID: peerUID) } catch { close(fd); throw error }
        return fd
    }

    public static func accept(_ listener: LinkHandle) throws -> LinkHandle {
        let fd = Glibc_or_Darwin_accept(listener, nil, nil)
        guard fd >= 0 else { throw failure("Accepting a link connection") }
        return fd
    }

    /// Refuses a connection whose other end isn't this user.
    public static func checkPeer(_ fd: LinkHandle, peerUID: (LinkHandle) throws -> uid_t = LinkSocket.peerUID) throws {
        guard try peerUID(fd) == getuid() else { throw LinkError.wrongPeer }
    }

    /// The uid at the other end of a connected socket.
    public static func peerUID(_ fd: LinkHandle) throws -> uid_t {
        #if canImport(Glibc)
        var cred = ucred()
        var size = socklen_t(MemoryLayout<ucred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &size) == 0 else { throw failure("Checking the link's other end") }
        return cred.uid
        #else
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { throw failure("Checking the link's other end") }
        return uid
        #endif
    }

    public static func writeLine(_ fd: LinkHandle, _ data: Data) throws {
        var bytes = data
        bytes.append(0x0A)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw failure("Writing to the link") }
            offset += n
        }
    }

    static func read(_ fd: LinkHandle, max: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = Glibc_or_Darwin_read(fd, &buffer, max)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw failure("Reading the link") }
            return Data(buffer[0..<n])
        }
    }

    public static func close(_ fd: LinkHandle) { _ = Glibc_or_Darwin_close(fd) }

    /// A connected pair, for tests.
    static func pair() throws -> (LinkHandle, LinkHandle) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, stream, 0, &fds) == 0 else { throw failure("Making a socket pair") }
        return (fds[0], fds[1])
    }
}

// The C functions under names that don't collide with LinkSocket's own.
private func Glibc_or_Darwin_listen(_ fd: Int32, _ n: Int32) -> Int32 { listen(fd, n) }
private func Glibc_or_Darwin_connect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
private func Glibc_or_Darwin_accept(_ fd: Int32, _ a: UnsafeMutablePointer<sockaddr>?, _ l: UnsafeMutablePointer<socklen_t>?) -> Int32 { accept(fd, a, l) }
private func Glibc_or_Darwin_read(_ fd: Int32, _ b: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, b, n) }
private func Glibc_or_Darwin_close(_ fd: Int32) -> Int32 { close(fd) }
#endif

/// What reading one line off the link gives.
public enum LinkLine: Equatable {
    case line(Data)
    /// A line longer than the cap: dropped up to its newline, and reported so the host can answer with an error.
    case tooLong
}

/// Splits a connection into lines, holding back what's left after the last newline. A line over `max` bytes is dropped and
/// reported as `.tooLong`, and reading carries on after it.
public final class LinkReader {
    let fd: LinkHandle
    let max: Int
    private var buffer = Data()
    private var skipping = false

    public init(_ fd: LinkHandle, max: Int) {
        self.fd = fd
        self.max = max
    }

    /// The next line, or nil at the end of the stream.
    public func next() throws -> LinkLine? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                if skipping { skipping = false; return .tooLong }
                return line.count > max ? .tooLong : .line(Data(line))
            }
            if buffer.count > max { skipping = true; buffer.removeAll() }
            #if os(Windows)
            let chunk = try LinkSocketWindows.receive(fd)
            #else
            let chunk = try LinkSocket.read(fd, max: 65536)
            #endif
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
