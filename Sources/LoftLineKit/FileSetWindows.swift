#if os(Windows)
import Foundation
import WinSDK

/// A file created only if nothing is at its name, on Windows: written beside the name, then moved there with MoveFileExW,
/// which refuses an existing destination when not told to replace it.
public enum ExclusiveFile {
    /// True when the file was created, false when something is already at `url`.
    public static func write(_ data: Data, to url: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try move(temporary, to: url)
    }

    /// True when moved, false when something is already at `destination`.
    public static func move(_ source: URL, to destination: URL) throws -> Bool {
        let moved = source.path.withCString(encodedAs: UTF16.self) { from in
            destination.path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        if moved { return true }
        let code = GetLastError()
        if code == DWORD(ERROR_ALREADY_EXISTS) || code == DWORD(ERROR_FILE_EXISTS) { return false }
        throw NSError(domain: "Win32", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "Windows error \(code) moving \(source.lastPathComponent).",
        ])
    }
}

extension GCodeFileSet {
    /// A folder a save works in, on Windows. It holds the path and not an open handle (one would stop the folder being removed), so
    /// unlike the Mac and Linux a folder renamed in the middle of a save isn't followed. It remembers which folder it opened, and every
    /// file operation checks that first: something else at that path stops the save, and nothing is written to or removed from it
    /// (docs/PLATFORMS.md).
    public final class Folder {
        public let url: URL
        private let identity: Identity

        /// Which folder a path names: its volume and file index. A link or junction at the path has its own, so a swap shows.
        struct Identity: Equatable {
            var volume: DWORD, indexHigh: DWORD, indexLow: DWORD

            init?(of url: URL) {
                let handle = url.path.withCString(encodedAs: UTF16.self) {
                    CreateFileW($0, 0, DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
                                DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
                }
                guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
                defer { CloseHandle(handle) }
                var info = BY_HANDLE_FILE_INFORMATION()
                guard GetFileInformationByHandle(handle, &info) else { return nil }
                volume = info.dwVolumeSerialNumber
                indexHigh = info.nFileIndexHigh
                indexLow = info.nFileIndexLow
            }
        }

        private init(url: URL) throws {
            guard let identity = Identity(of: url) else { throw CocoaError(.fileNoSuchFile) }
            self.url = url
            self.identity = identity
        }

        /// Throws unless the path still names the folder this opened.
        func check() throws {
            guard Identity(of: url) == identity else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        }

        public static func open(_ url: URL) throws -> Folder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Folder(url: url.standardizedFileURL)
        }

        public static func make(in parent: Folder, named name: String) throws -> Folder {
            try parent.check()
            let url = parent.url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return try Folder(url: url)
        }

        public func isFolder(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        public var currentURL: URL { url }

        /// True while `name` in `parent` is this folder.
        public func isStill(in parent: Folder, named name: String) -> Bool {
            parent.isFolder(name) && Identity(of: parent.url.appendingPathComponent(name, isDirectory: true)) == identity
        }
    }
}

extension GCodeFileSet.FileOperations {
    public static let live = GCodeFileSet.FileOperations(
        openFolder: GCodeFileSet.Folder.open,
        makeFolder: GCodeFileSet.Folder.make(in:named:),
        writeText: { text, folder, name in
            try folder.check()
            let url = folder.url.appendingPathComponent(name)
            guard try ExclusiveFile.write(Data(text.utf8), to: url) else { throw CocoaError(.fileWriteFileExists) }
        },
        moveItem: { from, fromName, to, toName in
            try from.check()
            try to.check()
            let source = from.url.appendingPathComponent(fromName), destination = to.url.appendingPathComponent(toName)
            guard try ExclusiveFile.move(source, to: destination) else { throw CocoaError(.fileWriteFileExists) }
        },
        // One file, link or empty folder, and never what a folder holds: FileManager's removeItem would take all of it.
        removeItem: { folder, name in
            try folder.check()
            let path = folder.url.appendingPathComponent(name).path
            let removed = path.withCString(encodedAs: UTF16.self) { wide -> Bool in
                let attributes = GetFileAttributesW(wide)
                guard attributes != DWORD.max else { return false }
                return attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 ? RemoveDirectoryW(wide) : DeleteFileW(wide)
            }
            guard removed else {
                throw NSError(domain: "Win32", code: Int(GetLastError()), userInfo: [NSLocalizedDescriptionKey: "Windows could not remove \(name)."])
            }
        })
}
#endif
