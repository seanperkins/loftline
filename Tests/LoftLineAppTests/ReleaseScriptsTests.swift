import Foundation
import Testing

/// The release workflow only orchestrates; the checks that decide whether a build may ship are scripts, tested here.
@Suite("Release scripts")
struct ReleaseScriptsTests {
    /// A temp directory removed with the test.
    final class Scratch {
        let dir: URL
        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("loftline-release-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, _ text: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
    }

    // MARK: scripts/check-test-run.sh

    static func passed(_ n: Int) -> String { "✔ Test run with \(n) tests in 3 suites passed after 1.234 seconds." }
    static func failed(_ n: Int) -> String { "✘ Test run with \(n) tests in 3 suites failed after 1.234 seconds with 2 issues." }

    /// What `scripts/test.sh` prints around its result lines.
    static func log(_ resultLines: [String]) -> String {
        (["Building for debugging...", "◇ Test run started.", "Executed 0 tests, with 0 failures"]
            + resultLines + ["exit code 0"]).joined(separator: "\n") + "\n"
    }

    func gate(_ text: String, minimum: String) throws -> ScriptRunner.Output {
        let box = try Scratch()
        let file = try box.write("test.log", text)
        return try ScriptRunner.script("scripts/check-test-run.sh", [file.path, minimum])
    }

    @Test func acceptsAllPassLinesWhoseSumReachesTheMinimum() throws {
        let text = Self.log([116, 659, 6, 338, 329].map(Self.passed))
        let ok = try gate(text, minimum: "1448")
        #expect(ok.status == 0, "\(ok.err)")
        #expect(ok.out.contains("1448"), "\(ok.out)")
    }

    @Test func sumsAcrossTargetLines() throws {
        let text = Self.log([100, 100, 100].map(Self.passed))
        #expect(try gate(text, minimum: "300").status == 0)
        let short = try gate(text, minimum: "301")
        #expect(short.status == 1)
        #expect(short.err.contains("300") && short.err.contains("301"), "\(short.err)")
    }

    @Test func readsTheSingularForms() throws {
        let text = Self.log(["✔ Test run with 1 test in 1 suite passed after 0.001 seconds.", Self.passed(9)])
        #expect(try gate(text, minimum: "10").status == 0)
    }

    @Test func rejectsWhenAnyTargetFailed() throws {
        let text = Self.log([Self.passed(500), Self.passed(500), Self.passed(500), Self.passed(500), Self.failed(5)])
        let result = try gate(text, minimum: "100")
        #expect(result.status == 1)
        #expect(result.err.contains("failed"), "\(result.err)")
    }

    @Test func rejectsFewerTestsThanTheMinimum() throws {
        let result = try gate(Self.log([Self.passed(100)]), minimum: "1200")
        #expect(result.status == 1)
        #expect(result.err.contains("100") && result.err.contains("1200"), "\(result.err)")
    }

    @Test func rejectsALogWithNoResultLine() throws {
        let result = try gate(Self.log([]), minimum: "1")
        #expect(result.status == 1)
        #expect(result.err.contains("no result line"), "\(result.err)")
    }

    @Test func rejectsAResultLineItCannotRead() throws {
        let result = try gate(Self.log([Self.passed(500), "Test run with lots of tests passed"]), minimum: "1")
        #expect(result.status == 1)
    }

    @Test func rejectsAMissingLogOrAMinimumThatIsNotANumber() throws {
        let box = try Scratch()
        let file = try box.write("test.log", Self.log([Self.passed(10)]))
        #expect(try ScriptRunner.script("scripts/check-test-run.sh", [box.dir.appendingPathComponent("none.log").path, "1"]).status == 1)
        #expect(try ScriptRunner.script("scripts/check-test-run.sh", [file.path, "many"]).status == 1)
        #expect(try ScriptRunner.script("scripts/check-test-run.sh", [file.path]).status == 1)
    }
}
