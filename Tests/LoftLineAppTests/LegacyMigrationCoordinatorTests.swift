import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// A copier that fails until told not to.
private final class FlakyCopy {
    var fails = true
    func copy(_ src: URL, _ dst: URL) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

@Suite struct LegacyMigrationCoordinatorTests {
    @Test @MainActor func failureIsRecordedThenRetryClearsIt() throws {
        let f = try LegacyKerfMigrationTests.Fixture(); defer { f.cleanUp() }
        try f.write("a", "a.json")
        let flaky = FlakyCopy()
        let c = LegacyMigrationCoordinator(migration: f.migration(copy: flaky.copy), environment: [:])
        c.runAtLaunch()
        #expect(c.failure != nil)
        flaky.fails = false
        #expect(c.resolve(.retry) == .completed)
        #expect(c.failure == nil)
        #expect(f.read("a.json") == "a")
    }

    @Test @MainActor func continueWithoutWritesSkippedAndClearsTheFailure() throws {
        let f = try LegacyKerfMigrationTests.Fixture(); defer { f.cleanUp() }
        try f.write("a", "a.json")
        let c = LegacyMigrationCoordinator(migration: f.migration(copy: FlakyCopy().copy), environment: [:])
        c.runAtLaunch()
        #expect(c.failure != nil)
        #expect(c.resolve(.continueWithout) == nil)
        #expect(c.failure == nil)
        #expect(f.defaults.string(forKey: LegacyKerfMigration.flagKey) == "skipped")
    }

    @Test @MainActor func noMigrationEnvVarSkipsTheRun() throws {
        let f = try LegacyKerfMigrationTests.Fixture(); defer { f.cleanUp() }
        try f.write("a", "a.json")
        let c = LegacyMigrationCoordinator(migration: f.migration(), environment: ["LOFTLINE_NO_MIGRATION": "1"])
        c.runAtLaunch()
        #expect(c.failure == nil)
        #expect(!FileManager.default.fileExists(atPath: f.newSupport.path))
        #expect(f.defaults.object(forKey: LegacyKerfMigration.flagKey) == nil)
    }

    /// Everything that reads Kerf's data (the tool library, preferences, machines, gadgets) is built after the migration has finished,
    /// including a failure the user resolves with Retry. So the alert is shown before `LoftLineApp.main()`, not from the launch delegate,
    /// where those consumers already hold pre-migration state. The migration runs after the command-line check so headless commands
    /// never copy user data or raise an alert.
    @Test func mainSwiftOrdersTheStartup() throws {
        let text = try Self.source("Sources/LoftLineApp/main.swift")
        let cli = try #require(text.range(of: "runIfRequested")).lowerBound
        let migration = try #require(text.range(of: "LegacyMigrationCoordinator.shared.runAtLaunch()")).lowerBound
        let alert = try #require(text.range(of: "LegacyMigrationCoordinator.shared.presentFailureIfNeeded()")).lowerBound
        let app = try #require(text.range(of: "LoftLineApp.main()")).lowerBound
        #expect(cli < migration && migration < alert && alert < app)
    }

    @Test func theLaunchDelegateDoesNotPresentTheMigrationAlert() throws {
        let text = try Self.source("Sources/LoftLineApp/App/LoftLineApp.swift")
        #expect(!text.contains("presentFailureIfNeeded"), "the alert must come before the app builds its models")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
