import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The one-time copy of Kerf data into LoftLine: files under Application Support and every `kerf.*` default.
@Suite struct LegacyKerfMigrationTests {
    /// Temp old and new support directories and a throwaway defaults domain.
    struct Fixture {
        let root: URL
        let oldSupport: URL
        let newSupport: URL
        let defaults: UserDefaults
        private let suite: String

        init() throws {
            let id = UUID().uuidString
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-tests-\(id)")
            oldSupport = root.appendingPathComponent("Kerf", isDirectory: true)
            newSupport = root.appendingPathComponent("LoftLine", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "loftline-tests-\(id)"
            defaults = UserDefaults(suiteName: suite)!
        }

        func write(_ text: String, _ relative: String, in dir: URL? = nil) throws {
            let url = (dir ?? oldSupport).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ relative: String, in dir: URL? = nil) -> String? {
            (try? String(contentsOf: (dir ?? newSupport).appendingPathComponent(relative), encoding: .utf8))
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: newSupport.appendingPathComponent(relative).path)
        }

        func migration(oldDefaults: [String: Any]? = nil,
                       copy: @escaping (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) })
            -> LegacyKerfMigration {
            LegacyKerfMigration(oldSupport: oldSupport, newSupport: newSupport, readOldDefaults: { oldDefaults },
                                defaults: defaults, copy: copy)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func copiesToolsJsonWhenTheDestinationIsMissing() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("{\"tools\":1}", "tools.json")
        #expect(f.migration().run() == .completed)
        #expect(f.read("tools.json") == "{\"tools\":1}")
        #expect(f.defaults.string(forKey: LegacyKerfMigration.flagKey) == "done")
    }

    @Test func neverOverwritesAnExistingDestinationFile() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("old", "tools.json")
        try f.write("new", "tools.json", in: f.newSupport)
        #expect(f.migration().run() == .completed)
        #expect(f.read("tools.json") == "new")
    }

    @Test func skipsTheRecoveryDirectory() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("{}", "Recovery/abc.kerf")
        try f.write("{}", "tools.json")
        #expect(f.migration().run() == .completed)
        #expect(f.exists("tools.json"))
        #expect(!f.exists("Recovery"))
    }

    @Test func renamesProjectAndToolExchangeExtensions() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("p", "templates/a.kerf")
        try f.write("t", "templates/x.kerftools")
        try f.write("q", "templates/y.kerftoolpaths")
        try f.write("g", "Gadgets/g.js")
        #expect(f.migration().run() == .completed)
        #expect(f.read("templates/a.loftline") == "p")
        #expect(f.read("templates/x.loftlinetools") == "t")
        #expect(f.read("templates/y.loftlinetoolpaths") == "q")
        #expect(f.read("Gadgets/g.js") == "g")
        #expect(!f.exists("templates/a.kerf"))
    }

    @Test func copiesEveryKerfDefaultsKeyByPrefix() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let old: [String: Any] = [
            "kerf.groupByTool": true,
            "kerf.pref.defaultUnits": "mm",
            "kerf.inspector.expanded.Tabs": true,
            "NSWindow Frame Kerf.welcome": "10 10 100 100 0 0 1440 900",
            "unrelated.key": 7,
        ]
        #expect(f.migration(oldDefaults: old).run() == .completed)
        #expect(f.defaults.bool(forKey: "loftline.groupByTool") == true)
        #expect(f.defaults.string(forKey: "loftline.pref.defaultUnits") == "mm")
        #expect(f.defaults.bool(forKey: "loftline.inspector.expanded.Tabs") == true)
        #expect(f.defaults.string(forKey: "NSWindow Frame LoftLine.welcome") == "10 10 100 100 0 0 1440 900")
        #expect(f.defaults.object(forKey: "unrelated.key") == nil)
        #expect(f.defaults.object(forKey: "kerf.groupByTool") == nil)
    }

    @Test func doesNotOverwriteAnExistingNewDefault() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.defaults.set("inch", forKey: "loftline.pref.defaultUnits")
        #expect(f.migration(oldDefaults: ["kerf.pref.defaultUnits": "mm"]).run() == .completed)
        #expect(f.defaults.string(forKey: "loftline.pref.defaultUnits") == "inch")
    }

    /// A copy that dies halfway: the second file leaves half its bytes under the temporary name, then throws.
    private func failingCopy(on name: String) -> (URL, URL) throws -> Void {
        { src, dst in
            if src.lastPathComponent == name {
                try Data([1]).write(to: dst)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }

    @Test func aFailedCopyLeavesNoPartialFileAndNoFlag() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("a", "a.json")
        try f.write("b", "b.json")
        let outcome = f.migration(copy: failingCopy(on: "b.json")).run()
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
        #expect(f.read("a.json") == "a")
        #expect(!f.exists("b.json"))
        #expect(!f.exists("b.json.migrating"))
        #expect(f.defaults.object(forKey: LegacyKerfMigration.flagKey) == nil)
    }

    @Test func retryAfterAFailureCompletes() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("a", "a.json")
        try f.write("b", "b.json")
        _ = f.migration(copy: failingCopy(on: "b.json")).run()
        #expect(f.migration().run() == .completed)
        #expect(f.read("a.json") == "a")
        #expect(f.read("b.json") == "b")
        #expect(f.defaults.string(forKey: LegacyKerfMigration.flagKey) == "done")
    }

    @Test func aFreshInstallIsNotNeeded() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        #expect(f.migration(oldDefaults: nil).run() == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: f.newSupport.path))
        #expect(f.defaults.string(forKey: LegacyKerfMigration.flagKey) == "done")
    }

    @Test func aSecondRunIsNotNeeded() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("{}", "tools.json")
        #expect(f.migration().run() == .completed)
        #expect(f.migration().run() == .notNeeded)
    }

    @Test func markSkippedStopsFutureRuns() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("{}", "tools.json")
        let m = f.migration()
        m.markSkipped()
        #expect(f.defaults.string(forKey: LegacyKerfMigration.flagKey) == "skipped")
        #expect(m.run() == .notNeeded)
        #expect(!f.exists("tools.json"))
    }

    /// An enumerator over an unreadable directory yields nothing and raises nothing, so the walk has to report it: otherwise the
    /// files are skipped, the flag is written, and restoring access later never imports them.
    @Test func anUnreadableSourceDirectoryIsAFailureNotACompletion() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("p", "templates/a.kerf")
        try f.write("t", "tools.json")
        let dir = f.oldSupport.appendingPathComponent("templates")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard case .failed = f.migration().run() else { Issue.record("an unreadable directory must fail"); return }
        #expect(f.defaults.object(forKey: LegacyKerfMigration.flagKey) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(f.migration().run() == .completed)
        #expect(f.read("templates/a.loftline") == "p")
    }

    @Test func renamesExtensionsWhateverTheirCase() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write("p", "templates/Panel.KERF")
        try f.write("t", "templates/Set.KerfTools")
        #expect(f.migration().run() == .completed)
        #expect(f.read("templates/Panel.loftline") == "p")
        #expect(f.read("templates/Set.loftlinetools") == "t")
    }

    /// A stored-key literal added later (or missed by the rename) must go through the migration, so none may live outside it.
    @Test func noKerfDefaultsKeyLiteralsRemainInSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let pattern = try NSRegularExpression(pattern: #""(kerf|Kerf)\."#)
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "LegacyKerfMigration.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 100, "the scan found only \(scanned) source files, so it checks nothing")
        #expect(offenders.isEmpty, "a kerf.* key literal outside the migration: \(offenders)")
    }
}
