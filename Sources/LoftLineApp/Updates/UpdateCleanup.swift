import Foundation

/// Housekeeping after an update.
enum UpdateCleanup {
    private static let oldPrefix = "LoftLine.old-"

    /// Deletes the `LoftLine.old-<pid>` folders beside `app`: what the update helper leaves behind when it is interrupted. Only
    /// that exact shape (digits after the dash) goes, so a folder a person named `LoftLine.old-backup` is left alone. Called
    /// once the new app has launched, so a missing app can still be recovered while it matters.
    static func removeOldBundles(besides app: URL) {
        let folder = app.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where isOldBundleName(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func isOldBundleName(_ name: String) -> Bool {
        guard name.hasPrefix(oldPrefix) else { return false }
        let suffix = name.dropFirst(oldPrefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
