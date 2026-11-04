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
    /// A folder a save works in, on Windows. It holds the path and not an open handle, so unlike the Mac and Linux a folder
    /// renamed in the middle of a save is not followed: the next file operation fails and the save rolls back
    /// (docs/PLATFORMS.md).
    public final class Folder {
        public let url: URL

        private init(url: URL) { self.url = url }

        public static func open(_ url: URL) throws -> Folder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
            return Folder(url: url.standardizedFileURL)
        }

        public static func make(in parent: Folder, named name: String) throws -> Folder {
            let url = parent.url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return Folder(url: url)
        }

        public func isFolder(_ name: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        public var currentURL: URL { url }

        /// True while `name` in `parent` is this folder's path. A folder swapped in at the same path is not told apart here.
        public func isStill(in parent: Folder, named name: String) -> Bool {
            parent.url.appendingPathComponent(name, isDirectory: true).standardizedFileURL == url.standardizedFileURL
                && parent.isFolder(name)
        }
    }
}

extension GCodeFileSet.FileOperations {
    public static let live = GCodeFileSet.FileOperations(
        openFolder: GCodeFileSet.Folder.open,
        makeFolder: GCodeFileSet.Folder.make(in:named:),
        writeText: { text, folder, name in
            let url = folder.url.appendingPathComponent(name)
            guard try ExclusiveFile.write(Data(text.utf8), to: url) else { throw CocoaError(.fileWriteFileExists) }
        },
        moveItem: { from, fromName, to, toName in
            let source = from.url.appendingPathComponent(fromName), destination = to.url.appendingPathComponent(toName)
            guard try ExclusiveFile.move(source, to: destination) else { throw CocoaError(.fileWriteFileExists) }
        },
        removeItem: { folder, name in
            try FileManager.default.removeItem(at: folder.url.appendingPathComponent(name))
        })
}
#endif
