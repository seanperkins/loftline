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

    // MARK: scripts/release-smoke.sh

    static let expectedDir = ScriptRunner.root.appendingPathComponent("samples/expected/generic-grbl-mm", isDirectory: true)

    /// A stand-in for the bundled executable (a test must not run `swift build` inside `swift test`; the real binary is
    /// exercised by scripts/check-bundle.sh). It records its arguments and "posts" by copying `source` to the --out folder.
    func fakeApp(in box: Scratch, copying source: URL, exitStatus: Int32 = 0) throws -> (app: URL, args: URL) {
        let app = box.dir.appendingPathComponent("LoftLine.app", isDirectory: true)
        let args = box.dir.appendingPathComponent("args.txt")
        _ = try box.write("LoftLine.app/Contents/MacOS/LoftLine", """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        [ "$1" = export ] || exit 64
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in --out) out="$2"; shift ;; esac
          shift
        done
        mkdir -p "$out" && cp '\(source.path)' "$out/sign.nc"
        exit \(exitStatus)

        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: app.appendingPathComponent("Contents/MacOS/LoftLine").path)
        return (app, args)
    }

    @Test func smokePassesWhenTheAppWritesTheGoldenBytes() throws {
        let box = try Scratch()
        let fake = try fakeApp(in: box, copying: Self.expectedDir.appendingPathComponent("sign.nc"))
        let result = try ScriptRunner.script("scripts/release-smoke.sh", [fake.app.path])
        #expect(result.status == 0, "\(result.err)")
    }

    @Test func smokeRunsTheBundledExportWithBuiltInPostsOnly() throws {
        let box = try Scratch()
        let fake = try fakeApp(in: box, copying: Self.expectedDir.appendingPathComponent("sign.nc"))
        try ScriptRunner.script("scripts/release-smoke.sh", [fake.app.path])
        let args = try String(contentsOf: fake.args, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args.first == "export")
        #expect(args.contains("samples/sign.loftline"))
        #expect(args.contains("--builtin-only"), "the smoke must not depend on whoever runs it: \(args)")
        #expect(args.contains("--quiet"))
        let post = try #require(args.firstIndex(of: "--post"))
        #expect(args[post + 1] == "generic-grbl-mm")
    }

    @Test func smokeFailsWhenAGoldenByteDiffers() throws {
        let box = try Scratch()
        let fake = try fakeApp(in: box, copying: Self.expectedDir.appendingPathComponent("sign.nc"))
        var bytes = try Data(contentsOf: Self.expectedDir.appendingPathComponent("sign.nc"))
        bytes[bytes.count / 2] ^= 0x01
        let changed = try box.write("expected/sign.nc", "")
        try bytes.write(to: changed)
        let result = try ScriptRunner.script("scripts/release-smoke.sh", [fake.app.path],
                                             env: ["LOFTLINE_SMOKE_EXPECTED_DIR": changed.deletingLastPathComponent().path])
        #expect(result.status != 0)
        #expect(result.err.contains("differ"), "\(result.err)")
    }

    @Test func smokeFailsWhenTheAppFailsOrIsMissing() throws {
        let box = try Scratch()
        let failing = try fakeApp(in: box, copying: Self.expectedDir.appendingPathComponent("sign.nc"), exitStatus: 3)
        #expect(try ScriptRunner.script("scripts/release-smoke.sh", [failing.app.path]).status != 0)
        let missing = box.dir.appendingPathComponent("Nowhere.app").path
        #expect(try ScriptRunner.script("scripts/release-smoke.sh", [missing]).status != 0)
        #expect(try ScriptRunner.script("scripts/release-smoke.sh").status != 0)
    }

    // MARK: .github/workflows/release.yml

    /// The workflow cannot run before it is merged, so its safety properties are checked from the file on every test run.
    @Test func theReleaseWorkflowPassesItsStructuralCheck() throws {
        let result = try ScriptRunner.script("scripts/check-release-workflow.sh")
        #expect(result.status == 0, "\(result.err)")
        #expect(result.out.contains("workflow checks passed"), "\(result.out)")
    }

    // MARK: scripts/configure-release-ci.sh

    static let configure = "scripts/configure-release-ci.sh"

    @Test func configureScriptRefusesTheRootkitVault() throws {
        let result = try ScriptRunner.script(Self.configure, ["/nonexistent.p12"],
                                             env: ["VAULT": "seanperkins/rootkit-macos-certs"])
        #expect(result.status != 0)
        #expect(result.err.contains("refusing"), "the guard must run before any other check: \(result.err)")
    }

    @Test func configureScriptRefusesTheRootkitRepoToo() throws {
        let result = try ScriptRunner.script(Self.configure, ["/nonexistent.p12"], env: ["REPO": "seanperkins/rootkit-game"])
        #expect(result.status != 0)
        #expect(result.err.contains("refusing"), "\(result.err)")
    }

    @Test func configureScriptHasNoSyntaxErrors() throws {
        let result = try ScriptRunner.exec("/bin/zsh", ["-n", ScriptRunner.root.appendingPathComponent(Self.configure).path])
        #expect(result.status == 0, "\(result.err)")
    }

    @Test func configureScriptWritesSecretsOnlyToItsOwnRepoAndNeverOnTheCommandLine() throws {
        let source = try String(contentsOf: ScriptRunner.root.appendingPathComponent(Self.configure), encoding: .utf8)
        let secretLines = source.split(separator: "\n").filter { $0.contains("gh secret set") }
        #expect(secretLines.count == 4, "MACOS_CERTS_DEPLOY_KEY, MACOS_CERT_PASSWORD, ASC_KEY_CONTENT, MACOS_IDENTITY")
        for line in secretLines {
            #expect(line.contains(#"--repo "$REPO""#), "\(line)")
            #expect(!line.contains("--body"), "a secret on the command line shows in the process list: \(line)")
        }
        #expect(!source.contains("leaving them"), "an existing deploy key must be replaced, not reused")
    }
}
