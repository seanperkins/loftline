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

        /// `<parent>/<name>/Contents/{Info.plist,marker}`; the marker tells old from new.
        @discardableResult
        func app(in parent: URL, named name: String = "LoftLine.app", marker: String) throws -> URL {
            let app = parent.appendingPathComponent(name, isDirectory: true)
            let contents = app.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
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

        func newArchive(marker: String = "new", at zip: URL? = nil, appName: String = "LoftLine.app") throws -> URL {
            let build = try folder("build-\(UUID().uuidString)")
            let app = try app(in: build, named: appName, marker: marker)
            return try archive(of: app, to: zip ?? dir.appendingPathComponent("LoftLine-update.zip"))
        }
    }

    static func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
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

    static func run(archive: URL, target: URL, pid: Int32, relaunch: Int = 0, state: URL? = nil,
                    skipCodesign: Bool = true, env: [String: String] = [:]) throws -> ScriptRunner.Output {
        var args = ["--archive", archive.path, "--target", target.path, "--pid", String(pid), "--relaunch", String(relaunch)]
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

    @Test func rejectsBadArguments() throws {
        let box = try Scratch()
        let target = try box.folder("Applications")
        let zip = try box.newArchive()
        #expect(try ScriptRunner.script(Self.helper, ["--archive", zip.path, "--target", target.path]).status != 0, "no --pid")
        #expect(try ScriptRunner.script(Self.helper, ["--archive", zip.path, "--target", target.path, "--pid", "abc"]).status != 0)
        #expect(try ScriptRunner.script(Self.helper, ["--archive", box.dir.appendingPathComponent("missing.zip").path,
                                                      "--target", target.path, "--pid", "1"]).status != 0)
        #expect(try ScriptRunner.script(Self.helper, ["--bogus"]).status != 0)
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
}
