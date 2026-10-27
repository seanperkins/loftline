import Foundation
import Testing

/// `packaging/updater/macos.sh` replaces the running app's bundle, so every way it can stop halfway is tested against
/// a fake bundle in a temp directory.
@Suite("Updater helper", .serialized)
struct UpdaterHelperTests {
    static let helper = "packaging/updater/macos.sh"
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// A temp directory removed with the test.
    final class Scratch {
        let dir: URL
        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("loftline-updater-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        func folder(_ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        /// `<parent>/<name>/Contents/{Info.plist,marker}`; the marker tells old from new, the version old from new in numbers.
        @discardableResult
        func app(in parent: URL, named name: String = "LoftLine.app", marker: String, version: String = "1.0.0") throws -> URL {
            let app = parent.appendingPathComponent(name, isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
            """
            try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
            try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
            return app
        }

        /// A zip made the way the release is: `ditto -c -k --keepParent`.
        func archive(of app: URL, to zip: URL) throws -> URL {
            try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try ScriptRunner.exec("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
            #expect(result.status == 0, "ditto: \(result.err)")
            return zip
        }

        func newArchive(marker: String = "new", at zip: URL? = nil, appName: String = "LoftLine.app", version: String = "2.0.0") throws -> URL {
            let build = try folder("build-\(UUID().uuidString)")
            let app = try app(in: build, named: appName, marker: marker, version: version)
            return try archive(of: app, to: zip ?? dir.appendingPathComponent("LoftLine-update.zip"))
        }

        /// A real, minimal bundle signed ad hoc with `identifier`: its signature is valid, but no team made it.
        @discardableResult
        func signedApp(in parent: URL, marker: String, identifier: String = "com.seanperkins.loftline", version: String = "2.0.0") throws -> URL {
            let app = parent.appendingPathComponent("LoftLine.app", isDirectory: true)
            let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
            <key>CFBundleExecutable</key><string>LoftLine</string>
            <key>CFBundleName</key><string>LoftLine</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            </dict></plist>
            """
            try Data(plist.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("LoftLine").path)
            try Data(marker.utf8).write(to: resources.appendingPathComponent("marker"))
            let signed = try ScriptRunner.exec("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, app.path])
            #expect(signed.status == 0, "codesign: \(signed.err)")
            return app
        }

        func newSignedArchive(marker: String = "new", identifier: String = "com.seanperkins.loftline", version: String = "2.0.0") throws -> URL {
            let build = try folder("signed-build-\(UUID().uuidString)")
            return try archive(of: try signedApp(in: build, marker: marker, identifier: identifier, version: version),
                               to: dir.appendingPathComponent("LoftLine-signed-update.zip"))
        }
    }

    /// The marker of a fake app (`Contents/marker`) or of a signed one (`Contents/Resources/marker`).
    static func marker(of app: URL) throws -> String {
        let plain = app.appendingPathComponent("Contents/marker")
        let url = FileManager.default.fileExists(atPath: plain.path) ? plain : app.appendingPathComponent("Contents/Resources/marker")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The SHA-256 the app would hand the helper: of the archive as it is right now.
    static func sha256(of file: URL) throws -> String {
        let result = try ScriptRunner.exec("/usr/bin/shasum", ["-a", "256", file.path])
        return String(result.out.split(separator: " ").first ?? "")
    }

    /// Every entry beside the app, hidden ones included.
    static func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// The pid of a process that has already exited and been reaped.
    static func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// Runs the helper the way the app does: with the digest of the archive as it is now, unless `sha256` says otherwise.
    static func run(archive: URL, target: URL, pid: Int32, relaunch: Int = 0, state: URL? = nil, sha256: String? = nil,
                    version: String = "2.0.0", skipCodesign: Bool = true, env: [String: String] = [:]) throws -> ScriptRunner.Output {
        var args = ["--archive", archive.path, "--target", target.path, "--pid", String(pid), "--relaunch", String(relaunch),
                    "--sha256", try sha256 ?? Self.sha256(of: archive), "--version", version]
        if let state { args += ["--state", state.path] }
        var environment = ["LOFTLINE_UPDATER_WAIT_SECONDS": "5"]
        if skipCodesign { environment["LOFTLINE_UPDATER_SKIP_CODESIGN"] = "1" }
        environment.merge(env) { _, new in new }
        return try ScriptRunner.script(helper, args, env: environment)
    }

    @Test func replacesTheBundleAndKeepsNoLeftovers() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()
        let state = box.dir.appendingPathComponent("update-state.json")
        try Data("{}".utf8).write(to: state)

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), state: state)

        #expect(result.status == 0, "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "new")
        #expect(try Self.names(in: target) == ["LoftLine.app"], "no LoftLine.old-* or .LoftLine-update-* may remain")
        #expect(!FileManager.default.fileExists(atPath: zip.path), "the archive is removed after a success")
        #expect(!FileManager.default.fileExists(atPath: state.path), "the state file is removed after a success")
    }

    @Test func abortsWithoutSwappingWhenThePidIsStillAlive() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }

        let result = try Self.run(archive: zip, target: target, pid: sleeper.processIdentifier,
                                  env: ["LOFTLINE_UPDATER_WAIT_SECONDS": "2"])

        #expect(result.status != 0)
        #expect(result.err.contains("still running"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
        #expect(FileManager.default.fileExists(atPath: zip.path), "the archive stays for the next attempt")
    }

    @Test func rollsBackWhenTheArchiveHasNoApp() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive(appName: "Other.app")

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID())

        #expect(result.status != 0)
        #expect(result.err.contains("no LoftLine.app"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"], "the staging folder is removed")
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func refusesAnUnsignedBundleUnlessToldNotToCheck() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), skipCodesign: false)

        #expect(result.status != 0)
        #expect(result.err.contains("signature"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
    }

    @Test func rejectsEachBadArgumentForItsOwnReason() throws {
        // Every argument is valid except the one under test, so a failure can only be that argument's: an absent --sha256 or
        // --version would stop the helper first and let every other check pass for the wrong reason.
        let box = try Scratch()
        let target = try box.folder("Applications")
        let zip = try box.newArchive()
        let digest = try Self.sha256(of: zip)
        let valid: [String: String] = ["--archive": zip.path, "--sha256": digest, "--version": "2.0.0",
                                       "--target": target.path, "--pid": "1"]
        /// `change` replaces an argument's value, or removes the argument when the value is nil.
        func run(_ change: [String: String?]) throws -> ScriptRunner.Output {
            var arguments: [String] = []
            for key in valid.keys.sorted() {
                if let override = change[key] {
                    if let value = override { arguments += [key, value] }
                } else {
                    arguments += [key, valid[key]!]
                }
            }
            return try ScriptRunner.script(Self.helper, arguments, env: ["LOFTLINE_UPDATER_SKIP_CODESIGN": "1"])
        }
        let missingZip = box.dir.appendingPathComponent("missing.zip").path
        let missingFolder = box.dir.appendingPathComponent("missing-folder").path
        let cases: [(change: [String: String?], message: String)] = [
            (["--pid": nil], "are required"),
            (["--pid": "abc"], "--pid must be a number"),
            (["--pid": "0"], "--pid must be a process id"),
            (["--archive": missingZip], "archive not found"),
            (["--target": missingFolder], "target folder not found"),
            (["--version": nil], "are required"),
            (["--version": "latest"], "--version must be a version number"),
            (["--version": "../2"], "--version must be a version number"),
            (["--version": "2.0 .0"], "--version must be a version number"),
            (["--sha256": nil], "are required"),
        ]
        for c in cases {
            let result = try run(c.change)
            #expect(result.status != 0, "\(c.change)")
            #expect(result.err.contains(c.message), "\(c.change): \(result.err)")
        }
        #expect(try ScriptRunner.script(Self.helper, ["--bogus"]).err.contains("unknown argument"))
        #expect(try ScriptRunner.script(Self.helper, ["--archive"]).err.contains("needs a value"))
    }

    @Test func handlesSpacesInEveryPath() throws {
        let box = try Scratch()
        let target = try box.folder("My Apps/Target Folder")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive(at: box.dir.appendingPathComponent("up date/New Build.zip"))
        let stateDir = try box.folder("state dir")
        let state = stateDir.appendingPathComponent("state file.json")
        try Data("{}".utf8).write(to: state)

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), state: state)

        #expect(result.status == 0, "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "new")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    @Test func faultBetweenRenamesLeavesNoAppAndRecoverRestoresTheOldOne() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()
        let pid = try Self.deadPID()

        let crashed = try Self.run(archive: zip, target: target, pid: pid, env: ["LOFTLINE_UPDATER_FAULT": "between-renames"])

        #expect(crashed.status == 42, "\(crashed.err)")
        let left = try Self.names(in: target)
        #expect(!left.contains("LoftLine.app"))
        #expect(left.contains("LoftLine.old-\(pid)"))

        let recovered = try ScriptRunner.script(Self.helper, ["--recover", target.path])

        #expect(recovered.status == 0, "\(recovered.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"], "the interrupted update's folders are cleared too")
    }

    @Test func recoverLeavesAnExistingAppAlone() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "current")
        try box.app(in: target, named: "LoftLine.old-123", marker: "older")

        let result = try ScriptRunner.script(Self.helper, ["--recover", target.path])

        #expect(result.status == 0, "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "current")
        #expect(try Self.names(in: target) == ["LoftLine.app", "LoftLine.old-123"], "nothing is deleted when the app is there")
    }

    /// A stub `open` first on PATH records what it was asked to open.
    private func stubOpen(in box: Scratch) throws -> (path: String, log: URL) {
        let bin = try box.folder("bin")
        let log = box.dir.appendingPathComponent("open.log")
        let script = bin.appendingPathComponent("open")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" >> '\(log.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ("\(bin.path):\(Self.systemPath)", log)
    }

    @Test func relaunchZeroDoesNotCallOpen() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let stub = try stubOpen(in: box)

        let result = try Self.run(archive: box.newArchive(), target: target, pid: Self.deadPID(), relaunch: 0,
                                  env: ["PATH": stub.path])

        #expect(result.status == 0, "\(result.err)")
        #expect(!FileManager.default.fileExists(atPath: stub.log.path))
    }

    @Test func relaunchOneOpensTheNewApp() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let stub = try stubOpen(in: box)

        let result = try Self.run(archive: box.newArchive(), target: target, pid: Self.deadPID(), relaunch: 1,
                                  env: ["PATH": stub.path])

        #expect(result.status == 0, "\(result.err)")
        let opened = try String(contentsOf: stub.log, encoding: .utf8)
        #expect(opened == target.appendingPathComponent("LoftLine.app").path + "\n")
    }

    // MARK: binding the install to the archive the app verified (docs/DECISIONS.md `updater-handoff`)

    @Test func refusesAnArchiveThatIsNotTheOneTheAppVerified() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), sha256: String(repeating: "0", count: 64))

        #expect(result.status != 0)
        #expect(result.err.contains("digest"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"], "nothing is staged beside the app before the digest matches")
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func refusesAnArchiveSwappedAfterTheAppVerifiedIt() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let verified = try box.newArchive(marker: "verified")
        let digest = try Self.sha256(of: verified)
        // Between the app's check and the install, a different (even perfectly well-formed) archive takes its place.
        let other = try box.newArchive(marker: "swapped", at: box.dir.appendingPathComponent("other.zip"))
        _ = try FileManager.default.replaceItemAt(verified, withItemAt: other)

        let result = try Self.run(archive: verified, target: target, pid: Self.deadPID(), sha256: digest)

        #expect(result.status != 0)
        #expect(result.err.contains("digest"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
    }

    @Test func requiresTheDigestAndRefusesAMalformedOne() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive()
        let base = ["--archive", zip.path, "--version", "2.0.0", "--target", target.path, "--pid", String(try Self.deadPID())]
        let env = ["LOFTLINE_UPDATER_SKIP_CODESIGN": "1"]

        let missing = try ScriptRunner.script(Self.helper, base, env: env)
        #expect(missing.status != 0)
        #expect(missing.err.contains("--sha256") && missing.err.contains("required"), "\(missing.err)")
        let good = try Self.sha256(of: zip)
        for bad in [good.uppercased(), String(good.dropLast()), good + "0", String(repeating: "g", count: 64)] {
            let result = try ScriptRunner.script(Self.helper, base + ["--sha256", bad], env: env)
            #expect(result.status != 0, "'\(bad)'")
            #expect(result.err.contains("--sha256 must be 64 lowercase hex characters"), "'\(bad)': \(result.err)")
        }
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
    }

    @Test func leavesNoWorkFolderBehindWhetherItInstallsOrRefuses() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let work = try box.folder("tmp")
        let zip = try box.newArchive()

        let refused = try Self.run(archive: zip, target: target, pid: Self.deadPID(), sha256: String(repeating: "1", count: 64),
                                   env: ["TMPDIR": work.path])
        #expect(refused.status != 0)
        #expect(try Self.names(in: work) == [], "a refused update removes its private copy")
        let installed = try Self.run(archive: zip, target: target, pid: Self.deadPID(), env: ["TMPDIR": work.path])
        #expect(installed.status == 0, "\(installed.err)")
        #expect(try Self.names(in: work) == [], "so does a successful one")
    }

    @Test func refusesABundleThatIsValidlySignedButNotByOurTeam() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newSignedArchive()

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), skipCodesign: false)

        #expect(result.status != 0)
        #expect(result.err.contains("signature"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
    }

    @Test func installsABundleThatMeetsTheRequirementAndRefusesOneThatDoesNot() throws {
        // The real requirement needs a Developer ID certificate, which a test cannot have. The mechanism is the same with
        // an identifier requirement, so both directions of it are exercised on an ad-hoc signed bundle.
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newSignedArchive()

        let wrong = try Self.run(archive: zip, target: target, pid: Self.deadPID(), skipCodesign: false,
                                 env: ["LOFTLINE_UPDATER_REQUIREMENT": #"identifier "com.example.someone-else""#])
        #expect(wrong.status != 0)
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")

        let right = try Self.run(archive: zip, target: target, pid: Self.deadPID(), skipCodesign: false,
                                 env: ["LOFTLINE_UPDATER_REQUIREMENT": #"identifier "com.seanperkins.loftline""#])
        #expect(right.status == 0, "\(right.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "new")
    }

    @Test func theDefaultRequirementPinsOurTeamTheDeveloperIDChainAndTheBundleIdentifier() throws {
        let source = try String(contentsOf: ScriptRunner.root.appendingPathComponent(Self.helper), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.hasPrefix("DEFAULT_REQUIREMENT=") }.map(String.init))
        #expect(line.contains("anchor apple generic"))
        #expect(line.contains(#"identifier \"com.seanperkins.loftline\""#))
        #expect(line.contains("certificate leaf[subject.OU] = \\\"$TEAM_ID\\\""))
        #expect(line.contains("1.2.840.113635.100.6.2.6"), "the Developer ID certification authority")
        #expect(line.contains("1.2.840.113635.100.6.1.13"), "a Developer ID Application leaf")
        #expect(source.contains(#"TEAM_ID="HH3SJBAS42""#))
    }

    // MARK: the version binding (a feed can claim any version; the signed bundle cannot)

    @Test func refusesAnArchiveThatIsNotNewerThanTheInstalledApp() throws {
        for (installed, offered) in [("2.0.0", "2.0.0"), ("2.0.0", "1.5.0"), ("2.0.10", "2.0.9"), ("1.10.0", "1.9.9")] {
            let box = try Scratch()
            let target = try box.folder("Applications")
            try box.app(in: target, marker: "old", version: installed)
            let zip = try box.newArchive(version: offered)

            let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), version: offered)

            #expect(result.status != 0, "\(offered) over \(installed)")
            #expect(result.err.contains("not newer"), "\(offered) over \(installed): \(result.err)")
            #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
            #expect(try Self.names(in: target) == ["LoftLine.app"], "nothing is left staged")
            #expect(FileManager.default.fileExists(atPath: zip.path))
        }
    }

    @Test func comparesVersionsAsNumbersNotText() throws {
        for (installed, offered) in [("2.0.9", "2.0.10"), ("1.9.0", "1.10.0"), ("0.9", "0.10.1"), ("1.0", "1.0.1"), ("1.0.0-rc1", "1.0.1")] {
            let box = try Scratch()
            let target = try box.folder("Applications")
            try box.app(in: target, marker: "old", version: installed)
            let zip = try box.newArchive(version: offered)

            let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), version: offered)

            #expect(result.status == 0, "\(offered) over \(installed): \(result.err)")
            #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "new")
        }
    }

    @Test func refusesAnArchiveWhoseVersionIsNotTheOneTheAppOffered() throws {
        // The feed said 3.0.0; the signed bundle says 2.0.0. What is installed must be what the user was shown.
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let zip = try box.newArchive(version: "2.0.0")

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID(), version: "3.0.0")

        #expect(result.status != 0)
        #expect(result.err.contains("not the 3.0.0 the app offered"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
        #expect(try Self.names(in: target) == ["LoftLine.app"])
    }

    @Test func installsWhenNoAppIsThereToCompareWith() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        let zip = try box.newArchive(version: "2.0.0")

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID())

        #expect(result.status == 0, "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "new")
    }

    @Test func refusesABundleWithNoReadableVersion() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        try box.app(in: target, marker: "old")
        let build = try box.folder("build-no-version")
        let app = try box.app(in: build, marker: "new")
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let zip = try box.archive(of: app, to: box.dir.appendingPathComponent("no-version.zip"))

        let result = try Self.run(archive: zip, target: target, pid: Self.deadPID())

        #expect(result.status != 0)
        #expect(result.err.contains("no readable version"), "\(result.err)")
        #expect(try Self.marker(of: target.appendingPathComponent("LoftLine.app")) == "old")
    }

    // MARK: the requirement string, run for real in CI

    @Test func printsTheRequirementAndCodesignAcceptsItsSyntax() throws {
        let printed = try ScriptRunner.script(Self.helper, ["--print-requirement"])
        #expect(printed.status == 0, "\(printed.err)")
        let requirement = printed.out.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(requirement.hasPrefix(#"identifier "com.seanperkins.loftline" and anchor apple generic"#), "\(requirement)")
        #expect(requirement.contains(#"certificate leaf[subject.OU] = "HH3SJBAS42""#), "\(requirement)")

        // Against an ad-hoc bundle the real requirement parses and fails to match (exit 3). A syntax error is exit 1 and says
        // so, which is what a typo in an OID or the requirement language would give, and what would refuse every install.
        let box = try Scratch()
        let app = try box.signedApp(in: try box.folder("check"), marker: "x")
        let checked = try ScriptRunner.exec("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", app.path])
        #expect(checked.status == 3, "exit \(checked.status): \(checked.err)")
        #expect(checked.err.contains("failed to satisfy"), "\(checked.err)")
        #expect(!checked.err.contains("syntax"), "\(checked.err)")
    }

    // MARK: the helper cleans up after itself and nothing else

    @Test func theAppsTempCopyRemovesItselfAndAnyOtherCopyStays() throws {
        let box = try Scratch()
        let source = ScriptRunner.root.appendingPathComponent(Self.helper)
        let appsCopy = box.dir.appendingPathComponent("loftline-updater-\(UUID().uuidString).sh")
        let otherCopy = box.dir.appendingPathComponent("macos-copy.sh")
        for copy in [appsCopy, otherCopy] { try FileManager.default.copyItem(at: source, to: copy) }

        // A run that ends in a refusal: the copy still has to clean up.
        let refused = try ScriptRunner.exec("/bin/bash", [appsCopy.path, "--bogus"])
        #expect(refused.status != 0)
        _ = try ScriptRunner.exec("/bin/bash", [otherCopy.path, "--bogus"])

        #expect(!FileManager.default.fileExists(atPath: appsCopy.path), "the temp copy the app started is removed when it ends")
        #expect(FileManager.default.fileExists(atPath: otherCopy.path), "a copy under any other name is never deleted")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
