import Foundation

public enum Trash {
    /// Moves a file where it can be recovered. On the Mac that is the Trash. Foundation has no trash off the Mac, so there it is a
    /// hidden `.trash` folder beside the file (docs/PLATFORMS.md).
    public static func move(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        let folder = url.deletingLastPathComponent().appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(url.pathExtension)"
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(name))
        #endif
    }
}
