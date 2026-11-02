import Darwin
import Foundation
import PostCore

/// A set of G-code programs that belong together (a job split into files, a sheet split into tiles)
/// and are saved as one: every file lands in the folder, or none does. A missing tile is the kind
/// of hole an operator does not notice until the sheet is cut, so a set with a program that failed
/// to post is not written at all, a file already in the folder is replaced only after the caller
/// has asked, the files that were there are kept in a hidden folder until the whole set is in, and
/// a failure part way through puts back what was there or says exactly where it is.
struct GCodeFileSet {
    struct File {
        var fileName: String
        /// What the file holds, for messages ("Tile 3", "Pocket 1").
        var title: String
        /// The program; nil when its post failed.
        var text: String?
    }

    /// An open directory, held for as long as a save works in it. Every operation is relative to
    /// one of these, so a folder renamed or swapped under the save after it was opened changes
    /// nothing: the save keeps working in the folder it opened.
    final class Folder {
        let fd: Int32
        /// Where it was opened, for messages and for tests that tell folders apart by name.
        let url: URL
        private let device: dev_t
        private let inode: ino_t

        private init(fd: Int32, url: URL) throws {
            var info = stat()
            guard fstat(fd, &info) == 0 else { let code = errno; close(fd); throw Folder.posixError(code, url.path) }
            self.fd = fd
            self.url = url
            device = info.st_dev
            inode = info.st_ino
        }

        deinit { close(fd) }

        /// The folder the user chose, by its real path (a user's alias is followed here, once).
        static func open(_ url: URL) throws -> Folder {
            guard let real = realpath(url.path, nil) else { throw posixError(errno, url.path) }
            defer { free(real) }
            let path = String(cString: real)
            let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw posixError(errno, path) }
            return try Folder(fd: fd, url: URL(fileURLWithPath: path, isDirectory: true))
        }

        /// A new folder inside `parent`, made and opened without following anything.
        static func make(in parent: Folder, named name: String) throws -> Folder {
            let url = parent.url.appendingPathComponent(name, isDirectory: true)
            guard mkdirat(parent.fd, name, 0o755) == 0 else { throw posixError(errno, url.path) }
            let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixError(errno, url.path) }
            return try Folder(fd: fd, url: url)
        }

        /// What `name` is in this folder, without following a link; nil when nothing is there.
        func type(of name: String) -> mode_t? {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return info.st_mode & S_IFMT
        }

        /// Where the folder is now, which is not where it was made if something renamed it meanwhile.
        var currentURL: URL {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return fcntl(fd, F_GETPATH, &buffer) == 0 ? URL(fileURLWithPath: String(cString: buffer), isDirectory: true) : url
        }

        /// True while `name` in `parent` is still this very folder and not something put in its place.
        func isStill(in parent: Folder, named name: String) -> Bool {
            var info = stat()
            guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return info.st_dev == device && info.st_ino == inode
        }

        fileprivate static func posixError(_ code: Int32, _ path: String) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "\(String(cString: strerror(code))) (\((path as NSString).lastPathComponent)).",
            ])
        }
    }

    /// The file operations a write uses, each relative to a held `Folder`. Tests swap in ones that
    /// fail on cue, so every rollback path is exercised; the app uses the live ones. `writeText`
    /// creates the file and fails when anything is at the name already; `moveItem` is an exclusive
    /// rename that never writes over an item at the destination, link or file. On a volume without
    /// exclusive rename a hard link, which is exclusive everywhere, stands in; on one without hard
    /// links either, the rename is check-then-rename, and a file created in that instant would be
    /// replaced. `removeItem` removes one file, link or empty folder and never recurses.
    struct FileOperations {
        var openFolder: (URL) throws -> Folder
        var makeFolder: (Folder, String) throws -> Folder
        var writeText: (String, Folder, String) throws -> Void
        var moveItem: (Folder, String, Folder, String) throws -> Void
        var removeItem: (Folder, String) throws -> Void

        static let live = FileOperations(
            openFolder: Folder.open,
            makeFolder: Folder.make(in:named:),
            writeText: { text, folder, name in
                let fd = openat(folder.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard fd >= 0 else { throw Folder.posixError(errno, folder.url.appendingPathComponent(name).path) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: Data(text.utf8))
                try handle.close()   // a network volume can report a failed write-behind only here
            },
            moveItem: { from, fromName, to, toName in
                if renameatx_np(from.fd, fromName, to.fd, toName, UInt32(RENAME_EXCL)) == 0 { return }
                var code = errno
                if code == ENOTSUP {
                    if linkat(from.fd, fromName, to.fd, toName, AT_SYMLINK_NOFOLLOW_ANY) == 0 {
                        guard unlinkat(from.fd, fromName, 0) == 0 else {
                            // Undo the link so that a throw still means nothing happened.
                            let failure = errno
                            unlinkat(to.fd, toName, 0)
                            throw Folder.posixError(failure, from.url.appendingPathComponent(fromName).path)
                        }
                        return
                    }
                    code = errno
                    if code == ENOTSUP || code == EPERM || code == EINVAL {
                        var info = stat()
                        if fstatat(to.fd, toName, &info, AT_SYMLINK_NOFOLLOW) == 0 { code = EEXIST }
                        else if renameat(from.fd, fromName, to.fd, toName) == 0 { return }
                        else { code = errno }
                    }
                }
                throw Folder.posixError(code, to.url.appendingPathComponent(toName).path)
            },
            removeItem: { folder, name in
                let path = folder.url.appendingPathComponent(name).path
                guard let type = folder.type(of: name) else { throw Folder.posixError(errno, path) }
                guard unlinkat(folder.fd, name, type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw Folder.posixError(errno, path) }
            })
    }

    var files: [File]
    var operations = FileOperations.live

    init(files: [File]) { self.files = files }

    /// The planned files of a Save All, in order.
    init(posted: [(file: PlannedGCodeFile, result: GCodeExportResult)]) {
        files = posted.map { File(fileName: $0.file.fileName, title: $0.file.title, text: $0.result.fileText) }
    }

    /// The tiles of a tiled export, in order.
    init(tiles: [TiledExport.File]) {
        files = tiles.map { File(fileName: $0.fileName, title: $0.title, text: $0.result.fileText) }
    }

    /// Titles of the files that have no program. While there are any, nothing is written.
    var unposted: [String] { files.filter { $0.text == nil }.map(\.title) }

    /// The key under which the file system (APFS folds case and Unicode form) files a name.
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// Name of the hidden working folder a write makes inside the chosen folder, and of the folder
    /// inside it that holds the files being replaced.
    static let workingFolderPrefix = ".loftline-save-"
    static let replacedFolderName = "was"

    /// Names the folder cannot take as one file each: empty, "." or "..", a path rather than a name,
    /// a NUL, the working folder's own `was`, or a name another file in the set shares once the file
    /// system folds case and Unicode form, which would make two programs one file. Nothing is
    /// written while there are any.
    var invalidNames: [String] {
        var seen: [String: Int] = [:]
        for f in files { seen[Self.collisionKey(f.fileName), default: 0] += 1 }
        return files.map(\.fileName).filter { name in
            name.isEmpty || name == "." || name == ".." || name == Self.replacedFolderName
                || name.contains("/") || name.contains("\0") || seen[Self.collisionKey(name), default: 0] > 1
        }
    }

    /// Names of planned files already in `directory` (a file or a symbolic link, not a directory);
    /// the caller asks before they are replaced.
    func existing(in directory: URL) -> [String] {
        let found = (try? inspect(directory)) ?? [:]
        return files.map(\.fileName).filter { found[$0] != nil && found[$0] != .typeDirectory }
    }

    /// Planned names that are symbolic links in `directory`: the link itself is replaced by a file,
    /// and what it pointed to is left as it is, which the caller should say.
    func links(in directory: URL) -> [String] {
        let found = (try? inspect(directory)) ?? [:]
        return files.map(\.fileName).filter { found[$0] == .typeSymbolicLink }
    }

    /// True when writing into `directory` would replace a file that is there now.
    func needsReplaceConfirmation(in directory: URL) -> Bool { !existing(in: directory).isEmpty }

    /// What is at each planned name in `directory`, without following a final symbolic link; a name
    /// with nothing at it is absent. Throws when a name could not be looked at for any reason other
    /// than there being nothing there, so a folder that cannot be read fails closed.
    private func inspect(_ directory: URL) throws -> [String: FileAttributeType] {
        var found: [String: FileAttributeType] = [:]
        for name in files.map(\.fileName) {
            do {
                found[name] = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.type] as? FileAttributeType
            } catch let error as NSError {
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                if error.code == NSFileReadNoSuchFileError || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT)) {
                    continue
                }
                throw GCodeFileSetError.couldNotRead(file: name, underlying: error)
            }
        }
        return found
    }

    /// Writes every file into `directory` or none. Refuses while any post failed, any name is not a
    /// plain unique file name, a planned name is a directory, or a file is there that the caller did
    /// not confirm (`confirmed`: the names shown to the user). Then every program is written into a
    /// hidden working folder inside `directory` (same volume, and nothing visible has changed), and
    /// each file goes into place by two renames: the file that was there into `was/` inside the
    /// working folder, then the new one onto its name. Both renames are exclusive, so a file that
    /// appeared in the meantime stops the save rather than being lost. The chosen folder, the
    /// working folder and `was/` are opened once and held, every operation is relative to them, and
    /// the working folder is cleaned out by name, never recursively, and removed only while it is
    /// still the folder that was opened. A failure removes the new files and renames the files that
    /// were there back; if
    /// even that fails the working folder is kept and the error says which earlier files are in it.
    /// On success the working folder, old files included, is removed. A crash part way through
    /// leaves the working folder in the user's folder, not in a temporary one. Returns the written
    /// URLs in order.
    @discardableResult
    func write(to directory: URL, replacing confirmed: [String] = []) throws -> [URL] {
        let missing = unposted
        guard missing.isEmpty else { throw GCodeFileSetError.notPosted(missing) }
        let bad = invalidNames
        guard bad.isEmpty else { throw GCodeFileSetError.invalidNames(bad) }
        let dir: Folder
        do { dir = try operations.openFolder(directory) } catch { throw GCodeFileSetError.couldNotStage(error) }
        let found = try inspect(dir.url)
        let inTheWay = files.map(\.fileName).filter { found[$0] == .typeDirectory }
        guard inTheWay.isEmpty else { throw GCodeFileSetError.directoryInTheWay(inTheWay) }
        let present = Set(found.keys)
        let unconfirmed = present.subtracting(confirmed).sorted()
        guard unconfirmed.isEmpty else { throw GCodeFileSetError.notConfirmed(unconfirmed) }

        let stagingName = Self.workingFolderPrefix + String(UUID().uuidString.prefix(8)).lowercased()
        let staging: Folder, was: Folder
        do { staging = try operations.makeFolder(dir, stagingName) } catch { throw GCodeFileSetError.couldNotStage(error) }
        do { was = try operations.makeFolder(staging, Self.replacedFolderName) } catch {
            if staging.isStill(in: dir, named: stagingName) { try? operations.removeItem(dir, stagingName) }
            throw GCodeFileSetError.couldNotStage(error)
        }
        // `aside` holds the names whose old file is in was/, `placed` the names whose new file is in
        // place; each is appended after the rename that made it true, and a rename that throws did
        // nothing. The working folder is held, so cleaning it out by the set's names (a write that
        // failed part way leaves one) reaches nothing else, and it is removed only while it is
        // still itself, so something swapped in at its name is neither emptied nor deleted.
        var aside: [String] = [], placed: [String] = []
        var keepWorkingFolder = false
        defer {
            if !keepWorkingFolder {
                for file in files where !placed.contains(file.fileName) { try? operations.removeItem(staging, file.fileName) }
                for name in aside { try? operations.removeItem(was, name) }
                try? operations.removeItem(staging, Self.replacedFolderName)
                if staging.isStill(in: dir, named: stagingName) { try? operations.removeItem(dir, stagingName) }
            }
        }

        // 1. Every program into the working folder: nothing the user can see has changed. The create
        //    is exclusive, so two names the volume folds into one fail here, on the second.
        for file in files {
            do { try operations.writeText(file.text!, staging, file.fileName) }
            catch { throw GCodeFileSetError.writeFailed(file: file.fileName, title: file.title, underlying: error) }
        }

        // 2. Into place by renames.
        for file in files {
            let name = file.fileName
            do {
                if present.contains(name) {
                    try operations.moveItem(dir, name, was, name)
                    aside.append(name)
                    // A directory that took the name after the check must not be treated as a file.
                    if was.type(of: name) == S_IFDIR { throw GCodeFileSetError.directoryInTheWay([name]) }
                }
                try operations.moveItem(staging, name, dir, name)
                placed.append(name)
            } catch {
                var newLeft: [String] = [], oldLeft: [String] = []
                for n in placed.reversed() {
                    do { try operations.removeItem(dir, n) } catch { newLeft.append(n) }
                }
                for n in aside.reversed() {
                    do { try operations.moveItem(was, n, dir, n) } catch { oldLeft.append(n) }
                }
                if newLeft.isEmpty && oldLeft.isEmpty {
                    if let refusal = error as? GCodeFileSetError { throw refusal }
                    throw GCodeFileSetError.writeFailed(file: name, title: file.title, underlying: error)
                }
                keepWorkingFolder = !oldLeft.isEmpty
                throw GCodeFileSetError.rollbackFailed(file: name, underlying: error, newLeft: newLeft,
                                                       oldLeft: oldLeft, workingFolder: was.currentURL)
            }
        }
        // 3. The set is in place: the working folder, old files included, goes with the defer.
        return files.map { dir.url.appendingPathComponent($0.fileName) }
    }
}

enum GCodeFileSetError: LocalizedError {
    /// Programs that could not be generated, by title; nothing was written.
    case notPosted([String])
    /// Names the folder cannot take as one file each; nothing was written.
    case invalidNames([String])
    /// Planned names that are directories in the folder; nothing was written.
    case directoryInTheWay([String])
    /// Files in the folder the user was not asked about; nothing was written.
    case notConfirmed([String])
    /// A planned name in the folder could not be looked at; nothing was written.
    case couldNotRead(file: String, underlying: Error)
    /// The folder could not be opened or the hidden working folder could not be made; nothing was written.
    case couldNotStage(Error)
    /// A file could not be written or put in place; the folder is as it was.
    case writeFailed(file: String, title: String, underlying: Error)
    /// A file could not be put in place and the folder could not be put back: `newLeft` are files
    /// from this save still in the folder, `oldLeft` are earlier files still in `workingFolder`.
    case rollbackFailed(file: String, underlying: Error, newLeft: [String], oldLeft: [String], workingFolder: URL)

    /// The cause alone, for a refusal that happened mid-save and is quoted inside another message.
    private var brief: String {
        switch self {
        case .directoryInTheWay(let names): return "\(names.joined(separator: ", ")) became a folder during the save."
        case .couldNotRead(let file, let underlying): return "\(file) could not be checked: \(underlying.localizedDescription)"
        default: return errorDescription ?? ""
        }
    }

    var errorDescription: String? {
        func list(_ names: [String]) -> String { names.joined(separator: ", ") }
        func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch self {
        case .notPosted(let titles):
            return "\(count(titles.count, "program")) could not be generated (\(list(titles))). "
                + "Nothing was saved: a set with a file missing would cut the job with a piece left out."
        case .invalidNames(let names):
            return "\(count(names.count, "file name")) cannot be used in one folder (\(list(names))). Nothing was saved."
        case .directoryInTheWay(let names):
            return "The folder has a folder, not a file, named \(list(names)). LoftLine does not replace folders. Nothing was saved."
        case .notConfirmed(let names):
            return "\(count(names.count, "file")) appeared in the folder after you were asked (\(list(names))). Nothing was saved; save again to be asked about \(names.count == 1 ? "it" : "them")."
        case .couldNotRead(let file, let underlying):
            return "Could not check whether \(file) is already in the folder: \(underlying.localizedDescription) Nothing was saved."
        case .couldNotStage(let error):
            return "Could not make a working folder beside the files: \(error.localizedDescription) Nothing was saved."
        case .writeFailed(let file, let title, let underlying):
            return "Could not write \(file) (\(title)): \(underlying.localizedDescription) "
                + "Nothing from this save was kept, and the files that were in the folder are as they were."
        case .rollbackFailed(let file, let underlying, let newLeft, let oldLeft, let workingFolder):
            let cause = (underlying as? GCodeFileSetError)?.brief ?? underlying.localizedDescription
            var parts = ["Could not write \(file): \(cause) Putting the folder back failed too."]
            if !newLeft.isEmpty {
                parts.append("Still in the folder from this save, do not run as a set: \(list(newLeft)).")
            }
            if !oldLeft.isEmpty {
                parts.append("Your earlier files are in \(workingFolder.path): \(list(oldLeft)). Move them back by hand.")
            }
            return parts.joined(separator: " ")
        }
    }
}
