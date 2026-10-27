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

    /// Swift Testing 6.1 (Xcode 16.4, the macos-15 runner's default) prints no "in N suites" clause.
    static func passedWithoutSuites(_ n: Int) -> String { "✔ Test run with \(n) tests passed after 1.234 seconds." }
    static func failedWithoutSuites(_ n: Int) -> String { "✘ Test run with \(n) tests failed after 1.234 seconds with 2 issues." }

    func gate(_ text: String, minimum: String, targets: String? = nil) throws -> ScriptRunner.Output {
        let box = try Scratch()
        let file = try box.write("test.log", text)
        return try ScriptRunner.script("scripts/check-test-run.sh", [file.path, minimum] + (targets.map { [$0] } ?? []))
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

    @Test func readsTheFormatWithoutSuiteCounts() throws {
        let ok = try gate(Self.log([116, 659, 6, 338, 329].map(Self.passedWithoutSuites)), minimum: "1448")
        #expect(ok.status == 0, "\(ok.err)")
        let bad = try gate(Self.log([Self.passedWithoutSuites(500), Self.failedWithoutSuites(5)]), minimum: "1")
        #expect(bad.status == 1)
        #expect(bad.err.contains("failed"), "\(bad.err)")
    }

    @Test func rejectsAMissingTargetEvenWhenTheTotalIsAboveTheMinimum() throws {
        // The 6-test CGeom target printed nothing: 1,496 tests still clear a minimum of 1,450.
        let missing = Self.log([116, 712, 338, 330].map(Self.passed))
        #expect(try gate(missing, minimum: "1450").status == 0, "the total alone cannot see a missing small target")
        let result = try gate(missing, minimum: "1450", targets: "5")
        #expect(result.status == 1)
        #expect(result.err.contains("5") && result.err.contains("4"), "expected 5 result lines, found 4: \(result.err)")
        #expect(try gate(Self.log([116, 712, 6, 338, 330].map(Self.passed)), minimum: "1450", targets: "5").status == 0)
        // A target that printed twice is not a target that ran.
        #expect(try gate(Self.log([116, 712, 6, 338, 330, 6].map(Self.passed)), minimum: "1450", targets: "5").status == 1)
    }

    @Test func acceptsTheOneCombinedLineOfAToolchainThatRunsEveryTargetTogether() throws {
        // Observed on the macos-15 runner (run 40538185730): Xcode 16.4's `swift test` runs all five targets in one process
        // and prints "Test run with 1514 tests passed" once, where a newer toolchain prints one line per target.
        let combined = Self.log([Self.passedWithoutSuites(1514)])
        let ok = try gate(combined, minimum: "1450", targets: "5")
        #expect(ok.status == 0, "\(ok.err)")
        #expect(ok.out.contains("1514") && ok.out.contains("combined"), "\(ok.out)")
        let failed = try gate(Self.log([Self.failedWithoutSuites(1514)]), minimum: "1450", targets: "5")
        #expect(failed.status == 1)
        #expect(failed.err.contains("failed"), "\(failed.err)")
    }

    @Test func aLoneLineBelowTheMinimumIsOneTargetNotACombinedRun() throws {
        // The largest target has 724 tests. Its line alone must not be read as "everything ran".
        let result = try gate(Self.log([Self.passedWithoutSuites(724)]), minimum: "1450", targets: "5")
        #expect(result.status == 1)
        #expect(result.err.contains("724") && result.err.contains("1450"), "\(result.err)")
    }

    @Test func rejectsAnExpectedTargetCountThatIsNotANumber() throws {
        #expect(try gate(Self.log([Self.passed(10)]), minimum: "1", targets: "five").status == 1)
        #expect(try gate(Self.log([Self.passed(10)]), minimum: "1", targets: "0").status == 1)
    }

    // MARK: scripts/check-release-state.sh

    /// A stand-in `gh` that answers `gh release view <tag> --json isDraft --jq .isDraft` the way STUB_GH_MODE says.
    func releaseState(_ mode: String, arguments: [String] = ["v1.2.3"]) throws -> ScriptRunner.Output {
        let box = try Scratch()
        let gh = try box.write("bin/gh", """
        #!/bin/sh
        case "$STUB_GH_MODE" in
          draft) echo true ;;
          published) echo false ;;
          absent) echo "release not found" >&2; exit 1 ;;
          *) echo "HTTP 500: server error" >&2; exit 1 ;;
        esac

        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        return try ScriptRunner.script("scripts/check-release-state.sh", arguments,
                                       env: ["PATH": "\(gh.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
                                             "STUB_GH_MODE": mode])
    }

    @Test func aTagWithNoReleaseOrADraftMayBeUploadedTo() throws {
        let absent = try releaseState("absent")
        #expect(absent.status == 0, "\(absent.err)")
        #expect(absent.out.contains("absent"), "\(absent.out)")
        let draft = try releaseState("draft")
        #expect(draft.status == 0, "\(draft.err)")
        #expect(draft.out.contains("draft"), "\(draft.out)")
    }

    @Test func aPublishedReleaseIsNeverTouched() throws {
        let result = try releaseState("published")
        #expect(result.status == 1)
        #expect(result.err.contains("already published"), "\(result.err)")
    }

    @Test func aLookupThatFailsForAnyOtherReasonStopsTheRelease() throws {
        let result = try releaseState("error")
        #expect(result.status == 1)
        #expect(result.err.contains("HTTP 500"), "the cause must be shown: \(result.err)")
        #expect(try releaseState("draft", arguments: []).status != 0, "a tag is required")
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

    @Test func configureScriptRefusesAVaultOrKeyTheWorkflowDoesNotUse() throws {
        // release.yml clones loftline-macos-certs and notarises with 4XBH56T7RS; a setup that provisioned anything else
        // would leave CI unable to authenticate while reporting success.
        for override in [["VAULT": "seanperkins/loftline-macos-certs-next"], ["ASC_KEY_ID": "ABCDE12345"]] {
            let result = try ScriptRunner.script(Self.configure, ["/nonexistent.p12"], env: override)
            #expect(result.status != 0)
            #expect(result.err.contains("refusing") && result.err.contains("release.yml"), "\(override): \(result.err)")
        }
        let defaults = try ScriptRunner.script(Self.configure, ["/nonexistent.p12"])
        #expect(defaults.status != 0)
        #expect(!defaults.err.contains("refusing"), "the defaults are what the workflow uses: \(defaults.err)")
    }

    @Test func configureScriptSaysSoWhenTheArgumentIsAPEMKeyInsteadOfTheExportedP12() throws {
        // The App Store Connect key is the easy mix-up: the script finds it itself, and OpenSSL's answer to a PEM file
        // ("wrong tag ... Type=PKCS12") says nothing about it. The agent sandbox refuses a file named *.p8, so a neutral name.
        let box = try Scratch()
        let pem = try box.write("asc-key.txt", "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n")
        let result = try ScriptRunner.script(Self.configure, [pem.path])
        #expect(result.status != 0)
        #expect(result.err.contains("not an exported .p12"), "\(result.err)")
        #expect(result.err.contains("finds"), "it should say the .p8 is found automatically: \(result.err)")
        #expect(!result.err.contains("openssl said"), "the guard must run before OpenSSL is asked: \(result.err)")
    }

    // The certificate-identity checks run the real script against a throwaway certificate, with a stub `gh` that records
    // every call, so they need an OpenSSL 3 (the script needs one too).
    static let openssl3: String? = {
        ["/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl",
         "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"].first { path in
            guard FileManager.default.isExecutableFile(atPath: path),
                  let version = try? ScriptRunner.exec(path, ["version"]) else { return false }
            return version.out.hasPrefix("OpenSSL 3")
        }
    }()

    /// Runs the setup script on a p12 whose certificate has `commonName`; returns its result and the `gh` calls it made.
    func configure(commonName: String, openssl: String, identity: String? = nil) throws -> (ScriptRunner.Output, [String]) {
        let box = try Scratch()
        let key = box.dir.appendingPathComponent("key.dat").path
        let cert = box.dir.appendingPathComponent("cert.dat").path
        let p12 = box.dir.appendingPathComponent("identity.bin").path
        try ScriptRunner.exec(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(commonName)",
                                        "-keyout", key, "-out", cert, "-days", "1"])
        try ScriptRunner.exec(openssl, ["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12, "-passout", "pass:pw"])
        // The agent sandbox refuses to create any file named *.p8, so the stand-in key has a neutral name.
        let ascKey = try box.write("asc-key.txt", "not a real key")
        let log = box.dir.appendingPathComponent("gh.log")
        let gh = try box.write("bin/gh", "#!/bin/sh\necho \"$@\" >> '\(log.path)'\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        var env = ["ASC_KEY_FILE": ascKey.path, "OPENSSL": openssl,
                   "PATH": "\(gh.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"]
        if let identity { env["MACOS_IDENTITY"] = identity }
        let result = try ScriptRunner.script(Self.configure, [p12], env: env, input: "pw\n")
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (result, calls)
    }

    @Test(.enabled(if: ReleaseScriptsTests.openssl3 != nil))
    func configureScriptRefusesAnotherTeamsCertificateBeforeTouchingGitHub() throws {
        let openssl = try #require(Self.openssl3)
        let (result, calls) = try configure(commonName: "Developer ID Application: Other Team (ZZZZZZZZZZ)", openssl: openssl)
        #expect(result.status != 0)
        #expect(result.err.contains("WRONG IDENTITY"), "\(result.err)")
        #expect(calls.isEmpty, "nothing may reach GitHub before the identity is verified: \(calls)")
    }

    @Test(.enabled(if: ReleaseScriptsTests.openssl3 != nil))
    func configureScriptContinuesToGitHubForTheIdentityItWasGiven() throws {
        let openssl = try #require(Self.openssl3)
        let (_, calls) = try configure(commonName: "Developer ID Application: Sean Perkins (HH3SJBAS42)", openssl: openssl)
        #expect(calls.first?.hasPrefix("repo view") == true, "the matching identity should reach the vault step: \(calls)")
        let (custom, customCalls) = try configure(commonName: "Developer ID Application: Someone Else (ABCDE12345)", openssl: openssl,
                                                  identity: "Developer ID Application: Someone Else (ABCDE12345)")
        #expect(customCalls.first?.hasPrefix("repo view") == true, "MACOS_IDENTITY names the identity to expect: \(custom.err)")
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
