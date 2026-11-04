import Foundation
import LoftLineKit

// `loftline-cli export …` (and `LoftLine export …`) posts a project and exits before the app, or any window system, starts.
if let status = LoftLineCLI.runIfRequested(CommandLine.arguments) { exit(status) }
// Kerf's data is copied before the app exists: the tool library loads while the SwiftUI `App` is built, and a library loaded
// too early would be the seeded one, which the next edit saves over the migrated file. After the CLI check, so headless commands
// never copy user data or raise an alert. A failure is resolved here too (Retry or Continue Without Importing), so everything the
// app builds afterwards reads the finished result.
// Top-level code in main.swift runs on the main thread but is not main-actor isolated for the compiler.
MainActor.assumeIsolated {
    LegacyMigrationCoordinator.shared.runAtLaunch()
    LegacyMigrationCoordinator.shared.presentFailureIfNeeded()
}
LoftLineApp.main()
