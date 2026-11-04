import AppKit
import Foundation
import LoftLineKit

/// Offers recovery copies left by a previous session that did not quit normally.
enum RecoveryPrompt {
    /// - Parameter interactive: true from the menu (also reports "nothing to recover").
    static func offer(store: RecoveryStore = RecoveryCoordinator.shared.store, interactive: Bool) {
        let owned = RecoveryCoordinator.shared.ownedIDs
        let entries = store.entries().filter { !owned.contains($0.id) }
        guard !entries.isEmpty else {
            if interactive {
                let a = NSAlert()
                a.messageText = "Nothing to recover"
                a.informativeText = "There are no unsaved documents from an earlier session. Older recovered copies are kept in the Archive folder."
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Show Archive")
                if a.runModal() == .alertSecondButtonReturn { showArchive(store) }
            }
            return
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let a = NSAlert()
        a.messageText = entries.count == 1 ? "Recover unsaved work?" : "Recover \(entries.count) unsaved documents?"
        a.informativeText = "LoftLine did not quit normally last time. These documents had changes that were not saved:\n\n"
            + entries.map { "• \($0.name) — \(df.string(from: $0.savedAt))" }.joined(separator: "\n")
            + "\n\nRecovered documents open as new, untitled windows. Save them to keep them."
        a.addButton(withTitle: "Recover")
        a.addButton(withTitle: "Not Now")
        a.addButton(withTitle: "Discard")
        switch a.runModal() {
        case .alertFirstButtonReturn: recover(entries, store: store)
        case .alertThirdButtonReturn: entries.forEach { store.archive($0.id) }
        default: break
        }
    }

    private static func recover(_ entries: [RecoveryEntry], store: RecoveryStore) {
        var failures: [String] = []
        for e in entries {
            do {
                _ = try NSDocumentController.shared.duplicateDocument(withContentsOf: store.projectURL(e.id), copying: true,
                                                                      displayName: "\(e.name) (Recovered)")
                store.archive(e.id)
            } catch {
                failures.append("\(e.name): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Some documents could not be reopened"
        a.informativeText = failures.joined(separator: "\n")
            + "\n\nThe recovery files are still in the Recovery folder; open them with File ▸ Open."
        a.addButton(withTitle: "Show Folder")
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(store.directory) }
    }

    private static func showArchive(_ store: RecoveryStore) {
        try? FileManager.default.createDirectory(at: store.archiveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.archiveDirectory)
    }
}
