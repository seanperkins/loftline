import AppKit
import Foundation
import LoftLineKit

/// Runs the Kerf migration at launch and owns what happens when it fails. A failure is never retried silently: LoftLine could
/// otherwise run, save a seeded `tools.json` over the missing one, and a later retry would skip that file and mark the migration
/// done with the real data stranded. The launch shows an alert instead, with Retry or Continue Without Importing.
@MainActor final class LegacyMigrationCoordinator {
    enum Choice { case retry, continueWithout }

    static let shared = LegacyMigrationCoordinator(migration: .standard())

    /// The reason the last run failed; nil when it has not, or after a retry succeeded or the user chose to continue.
    private(set) var failure: String?

    private let migration: LegacyKerfMigration
    private let environment: [String: String]

    init(migration: LegacyKerfMigration, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.migration = migration
        self.environment = environment
    }

    /// Called from `main.swift`, after the command-line check and before the app builds the tool library.
    /// `LOFTLINE_NO_MIGRATION=1` skips it (tests, CI).
    func runAtLaunch() {
        guard environment["LOFTLINE_NO_MIGRATION"] != "1" else { return }
        record(migration.run())
    }

    /// Retry re-runs the migration; Continue Without Importing writes the `skipped` flag (an explicit decision) and leaves the
    /// old data where it is. Returns the retry's outcome, nil for Continue. Nothing needs reloading afterwards: the alert runs
    /// before the app builds the tool library, preferences, machines or gadgets, so they all read the finished result.
    @discardableResult func resolve(_ choice: Choice) -> LegacyKerfMigration.Outcome? {
        switch choice {
        case .retry:
            let outcome = migration.run()
            record(outcome)
            return outcome
        case .continueWithout:
            migration.markSkipped()
            failure = nil
            return nil
        }
    }

    /// Called from `main.swift` right after `runAtLaunch()`, still before the app builds its models. An alert needs a running
    /// `NSApplication`, so this creates and activates it; the SwiftUI `App` reuses the same shared instance.
    func presentFailureIfNeeded() {
        guard failure != nil else { return }
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        while let reason = failure {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "LoftLine could not import your data from Kerf"
            alert.informativeText = "\(reason)\n\nYour Kerf data has not been changed. Retry, or continue without importing; "
                + "you can copy files from ~/Library/Application Support/Kerf yourself later."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Continue Without Importing")
            resolve(alert.runModal() == .alertFirstButtonReturn ? .retry : .continueWithout)
        }
    }

    private func record(_ outcome: LegacyKerfMigration.Outcome) {
        if case .failed(let reason) = outcome { failure = reason } else { failure = nil }
    }
}
