import Foundation
import Testing
import UpdateCore
@testable import LoftLineApp

/// Serves canned responses to a URLSession so the controller never touches the network.
final class StubURL: URLProtocol {
    static let lock = NSLock()
    static var responses: [URL: (status: Int, body: Data)] = [:]
    static var requests: [URLRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responses = [:]
        requests = []
    }
    static func serve(_ url: URL, _ body: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = (status, body)
    }
    static func requested() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let canned = request.url.flatMap { Self.responses[$0] }
        Self.lock.unlock()
        guard let url = request.url, let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(canned.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Test-only signing material, generated once per run (never committed, nothing credential-named on disk).
enum UpdateTestKeys {
    static let dir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-update-keys-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func make(_ name: String) -> (privateKey: URL, publicPEM: String) {
        let file = dir.appendingPathComponent("\(name).dat")
        let generated = try! ScriptRunner.exec("/usr/bin/openssl", ["genrsa", "-out", file.path, "4096"])
        precondition(generated.status == 0, generated.err)
        let pub = dir.appendingPathComponent("\(name).pub")
        let derived = try! ScriptRunner.exec("/usr/bin/openssl", ["rsa", "-in", file.path, "-RSAPublicKey_out", "-out", pub.path])
        precondition(derived.status == 0, derived.err)
        return (file, try! String(contentsOf: pub, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let signer = make("signer")
    static let other = make("other")
}

/// Everything the controller touches, in a temp folder.
final class Recorder: @unchecked Sendable {
    struct Spawn: Equatable {
        var archive: URL; var target: URL; var pid: Int32; var relaunch: Bool; var sha256: String; var version: String
    }
    private let lock = NSLock()
    private var _spawns: [Spawn] = []
    private var _terminations = 0
    var spawns: [Spawn] { lock.lock(); defer { lock.unlock() }; return _spawns }
    var terminations: Int { lock.lock(); defer { lock.unlock() }; return _terminations }
    func spawned(_ spawn: Spawn) { lock.lock(); _spawns.append(spawn); lock.unlock() }
    func terminated() { lock.lock(); _terminations += 1; lock.unlock() }
}

@MainActor
final class Rig {
    let box: URL
    let apps: URL
    let cache: URL
    let defaults: UserDefaults
    let suite: String
    let store: UpdateStateStore
    let recorder = Recorder()
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var controller: UpdateController!
    /// `StubURL` is process-wide state, so only the serialized controller suite may own (reset) it. A rig that merely hosts
    /// views must not: clearing it would pull the canned responses out from under a controller test running at the same time.
    private let ownsStub: Bool

    init(version: String = "0.2.0", channel: String = "release", bundleURL: URL? = nil, autoCheck: Bool = true,
         environment: [String: String] = [:], publicKey: String = UpdateTestKeys.signer.publicPEM,
         ownsStub: Bool = true) throws {
        self.ownsStub = ownsStub
        box = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-update-rig-\(UUID().uuidString)")
        apps = box.appendingPathComponent("Applications")
        cache = box.appendingPathComponent("Caches/Updates")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("LoftLine.app"), withIntermediateDirectories: true)
        suite = "loftline-tests-update-rig-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = UpdateStateStore(defaults: defaults)
        if ownsStub { StubURL.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURL.self]
        let installed = bundleURL ?? apps.appendingPathComponent("LoftLine.app")
        let recorder = self.recorder
        controller = UpdateController(
            session: URLSession(configuration: configuration), store: store,
            bundle: BundleInfo(version: version, channel: channel, bundleURL: installed),
            publicKeyPEM: publicKey, cacheDirectory: cache,
            autoCheckEnabled: { autoCheck },
            spawnHelper: { archive, target, pid, relaunch, sha256, version in
                recorder.spawned(.init(archive: archive, target: target, pid: pid, relaunch: relaunch, sha256: sha256, version: version))
            },
            terminate: { recorder.terminated() },
            environment: environment,
            now: { [unowned self] in self.clock })
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: apps.path)
        try? FileManager.default.removeItem(at: box)
        defaults.removePersistentDomain(forName: suite)
        if ownsStub { StubURL.reset() }
    }

    /// Signs `archive` with the real scripts/update-feed.sh and serves the feed and the archive; returns the parsed entry.
    @discardableResult
    func serve(version: String = "0.2.1", archive: Data = Data(repeating: 0x5a, count: 4096), key: URL = UpdateTestKeys.signer.privateKey,
               feedURL: URL = UpdateController.defaultFeedURL, editFeed: (inout [String: Any]) -> Void = { _ in }) throws -> UpdateEntry {
        let zip = box.appendingPathComponent("served-\(version).zip")
        try archive.write(to: zip)
        let out = box.appendingPathComponent("feed-\(version).json")
        let made = try ScriptRunner.script("scripts/update-feed.sh", ["v\(version)", "--zip", zip.path, "--out", out.path],
                                           env: ["UPDATE_SIGN_KEY_FILE": key.path])
        #expect(made.status == 0, "\(made.err)")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        let original = try #require(UpdateManifest.parse(try Data(contentsOf: out)))
        editFeed(&document)
        let data = try JSONSerialization.data(withJSONObject: document)
        StubURL.serve(feedURL, data)
        StubURL.serve(original.url, archive)
        return original
    }

    func cachedArchive(_ version: String = "0.2.1") -> URL { cache.appendingPathComponent("LoftLine-\(version).zip") }
    func cachedFiles() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [] }

    /// An update that is found and downloaded: ready to install.
    func readyToInstall(version: String = "0.2.1") async throws -> UpdateEntry {
        let entry = try serve(version: version)
        await controller.checkNow(userInitiated: true)
        await controller.download()
        #expect(controller.state == .readyToInstall(entry), "\(controller.state)")
        return entry
    }
}

@Suite("Update controller", .serialized)
@MainActor
struct UpdateControllerTests {
    // MARK: finding an update

    @Test func checkFindsANewerVersion() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try rig.serve(version: "0.2.1")

        await rig.controller.checkNow(userInitiated: true)

        #expect(rig.controller.state == .available(entry))
        #expect(rig.store.lastCheck == rig.clock)
        let request = try #require(StubURL.requested().first)
        #expect(request.url == UpdateController.defaultFeedURL)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "LoftLine/0.2.0")
    }

    @Test func sameOrOlderIsUpToDate() async throws {
        let rig = try Rig(version: "0.2.1")
        defer { rig.cleanup() }
        try rig.serve(version: "0.2.1")
        await rig.controller.checkNow(userInitiated: true)
        #expect(rig.controller.state == .upToDate)
        try rig.serve(version: "0.2.0")
        await rig.controller.checkNow(userInitiated: true)
        #expect(rig.controller.state == .upToDate)
    }

    @Test func skippedVersionIsNotOfferedAutomaticallyButAManualCheckStillShowsIt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try rig.serve(version: "0.2.1")
        await rig.controller.checkNow(userInitiated: true)
        rig.controller.skipVersion()
        #expect(rig.store.skippedVersion == "0.2.1")
        #expect(rig.controller.state == .idle)

        rig.clock = rig.clock.addingTimeInterval(2 * 86_400)
        await rig.controller.checkNow(userInitiated: false)
        #expect(rig.controller.state == .upToDate, "a skipped version is not offered by a background check")

        await rig.controller.checkNow(userInitiated: true)
        #expect(rig.controller.state == .available(entry), "asking by hand shows it again")
    }

    @Test func autoCheckHonoursThePreference() async throws {
        let on = try Rig(autoCheck: true)
        defer { on.cleanup() }
        #expect(on.controller.canAutoCheck)
        let off = try Rig(autoCheck: false)
        defer { off.cleanup() }
        #expect(!off.controller.canAutoCheck)
        try off.serve()
        await off.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().isEmpty, "no request when the preference is off")
        let silenced = try Rig(autoCheck: true, environment: ["LOFTLINE_NO_UPDATE_CHECK": "1"])
        defer { silenced.cleanup() }
        #expect(!silenced.controller.canAutoCheck)
        try silenced.serve()
        await silenced.controller.checkNow(userInitiated: true)
        guard case .failed = silenced.controller.state else { Issue.record("\(silenced.controller.state)"); return }
        #expect(StubURL.requested().isEmpty, "LOFTLINE_NO_UPDATE_CHECK=1 silences a manual check too")
    }

    @Test func devChannelNeverAutoChecksAndSaysSoWhenAsked() async throws {
        let rig = try Rig(channel: "dev")
        defer { rig.cleanup() }
        try rig.serve()
        #expect(!rig.controller.canAutoCheck)
        await rig.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().isEmpty)
        await rig.controller.checkNow(userInitiated: true)
        guard case .failed(let message) = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(message.lowercased().contains("development"), "\(message)")
        #expect(StubURL.requested().isEmpty, "a dev build without an override does not even ask")
    }

    @Test func rehearsalBuildsNeverCheckEither() async throws {
        let rig = try Rig(channel: "rehearsal")
        defer { rig.cleanup() }
        try rig.serve()
        #expect(!rig.controller.canAutoCheck)
        await rig.controller.checkNow(userInitiated: true)
        guard case .failed = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(StubURL.requested().isEmpty)
    }

    @Test func feedOverrideIsHonouredOnlyOnDev() async throws {
        let override = URL(string: "http://localhost:8123/latest.json")!
        let env = ["LOFTLINE_UPDATE_FEED_URL": override.absoluteString]
        let dev = try Rig(channel: "dev", environment: env)
        defer { dev.cleanup() }
        let entry = try dev.serve(version: "0.2.1", feedURL: override)
        await dev.controller.checkNow(userInitiated: true)
        #expect(dev.controller.state == .available(entry))
        #expect(StubURL.requested().first?.url == override)

        let release = try Rig(channel: "release", environment: env)
        defer { release.cleanup() }
        try release.serve(version: "0.2.1", feedURL: override)
        await release.controller.checkNow(userInitiated: true)
        #expect(StubURL.requested().first?.url == UpdateController.defaultFeedURL, "an override never moves a release build's feed")
    }

    @Test func aDevBuildThatFindsAnUpdateNeverInstallsIt() async throws {
        let override = URL(string: "http://localhost:8123/latest.json")!
        let rig = try Rig(channel: "dev", environment: ["LOFTLINE_UPDATE_FEED_URL": override.absoluteString])
        defer { rig.cleanup() }
        try rig.serve(feedURL: override)
        await rig.controller.checkNow(userInitiated: true)
        await rig.controller.download()
        rig.controller.installNow()
        guard case .failed(let message) = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(message.lowercased().contains("development"), "\(message)")
        #expect(rig.recorder.terminations == 0)
        #expect(rig.recorder.spawns.isEmpty)
    }

    @Test func automaticChecksAreThrottledToOncePerDay() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.serve()
        rig.store.lastCheck = rig.clock.addingTimeInterval(-3_600)
        await rig.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().isEmpty, "an hour after the last check is too soon")
        rig.store.lastCheck = rig.clock.addingTimeInterval(-25 * 3_600)
        await rig.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().count == 1)
        await rig.controller.checkNow(userInitiated: true)
        #expect(StubURL.requested().count == 2, "a manual check is never throttled")
    }

    @Test func aDailyTimerThatFiresJustBeforeTheDayIsUpStillChecks() async throws {
        // The launch check ends a few seconds after it starts, and the daily timer started when it did, so its first tick falls
        // a few seconds short of 24 h after the last check. Without slack every other tick is skipped: a check every 48 h.
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.serve()
        rig.store.lastCheck = rig.clock.addingTimeInterval(-(24 * 3_600 - 10))
        await rig.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().count == 1, "10 seconds short of a day counts as a day")
        rig.store.lastCheck = rig.clock.addingTimeInterval(-(24 * 3_600 - 600))
        await rig.controller.checkNow(userInitiated: false)
        #expect(StubURL.requested().count == 1, "ten minutes short is still too soon")
    }

    @Test func aFailedAutomaticCheckIsSilentAndAFailedManualOneReports() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        StubURL.serve(UpdateController.defaultFeedURL, Data("oops".utf8), status: 500)
        await rig.controller.checkNow(userInitiated: false)
        #expect(rig.controller.state == .idle)
        #expect(rig.store.lastCheck == nil, "a failed check does not count as a check")
        rig.clock = rig.clock.addingTimeInterval(2 * 86_400)
        await rig.controller.checkNow(userInitiated: true)
        guard case .failed = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
    }

    @Test func aHostileFeedIsRefusedWhole() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.serve { document in
            var entries = document["entries"] as! [String: [String: Any]]
            entries["macos-arm64"]!["url"] = "https://evil.example/LoftLine.zip"
            document["entries"] = entries
        }
        await rig.controller.checkNow(userInitiated: true)
        guard case .failed = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        StubURL.serve(UpdateController.defaultFeedURL, Data(repeating: 0x20, count: 600_000))
        await rig.controller.checkNow(userInitiated: true)
        guard case .failed = rig.controller.state else { Issue.record("an oversized feed: \(rig.controller.state)"); return }
    }

    // MARK: downloading

    @Test func downloadRejectsAShaMismatchAndDeletesTheFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.serve { document in
            var entries = document["entries"] as! [String: [String: Any]]
            entries["macos-arm64"]!["sha256"] = String(repeating: "0", count: 64)
            document["entries"] = entries
        }
        await rig.controller.checkNow(userInitiated: true)
        await rig.controller.download()
        guard case .failed(let message) = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(message.lowercased().contains("checksum"), "\(message)")
        #expect(rig.cachedFiles() == [], "nothing unverified is left in the cache")
    }

    @Test func downloadRejectsABadSignatureAndDeletesTheFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        // A good digest, signed by a key that is not ours.
        try rig.serve(key: UpdateTestKeys.other.privateKey)
        await rig.controller.checkNow(userInitiated: true)
        await rig.controller.download()
        guard case .failed(let message) = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(message.lowercased().contains("signature"), "\(message)")
        #expect(rig.cachedFiles() == [])
    }

    @Test func aNonOKDownloadFailsAndLeavesNothing() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try rig.serve()
        StubURL.serve(entry.url, Data("not found".utf8), status: 404)
        await rig.controller.checkNow(userInitiated: true)
        await rig.controller.download()
        guard case .failed = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(rig.cachedFiles() == [])
    }

    @Test func verifiedDownloadIsReadyToInstall() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let archive = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let entry = try rig.serve(archive: archive)
        await rig.controller.checkNow(userInitiated: true)
        await rig.controller.download()
        #expect(rig.controller.state == .readyToInstall(entry))
        #expect(try Data(contentsOf: rig.cachedArchive()) == archive)
        #expect(rig.cachedFiles() == ["LoftLine-0.2.1.zip"])
    }

    // MARK: installing

    @Test func translocatedCopyRefusesToInstall() async throws {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABCD/d/LoftLine.app")
        let rig = try Rig(bundleURL: translocated)
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        rig.controller.installNow()
        #expect(rig.controller.state == .failed("Move LoftLine to Applications first"))
        #expect(rig.recorder.terminations == 0)
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.isEmpty)
    }

    @Test func aRenamedBundleRefusesToInstall() async throws {
        // The helper installs to LoftLine.app beside the running app. Updating "LoftLine copy.app" would leave it untouched
        // and replace a different copy next to it.
        for name in ["LoftLine-old.app", "LoftLine copy.app", "LoftLine 2.app", "loftline.app", "LoftLine.app.app"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-renamed-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let rig = try Rig(bundleURL: folder.appendingPathComponent(name))
            defer { rig.cleanup() }
            _ = try await rig.readyToInstall()
            rig.controller.installOnQuit()
            guard case .failed(let message) = rig.controller.state else { Issue.record("\(name): \(rig.controller.state)"); continue }
            #expect(message.contains("LoftLine.app"), "\(name): \(message)")
            rig.controller.applicationWillTerminate()
            #expect(rig.recorder.spawns.isEmpty, "\(name)")
        }
    }

    @Test func unwritableTargetRefusesToInstall() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.apps.path)
        rig.controller.installOnQuit()
        guard case .failed(let message) = rig.controller.state else { Issue.record("\(rig.controller.state)"); return }
        #expect(message.contains("cannot be updated here") || message.contains("not writable"), "\(message)")
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.isEmpty)
    }

    @Test func installNowOnlyTerminatesAndDoesNotSpawn() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        rig.controller.installNow()
        #expect(rig.controller.state == .installPending(relaunch: true))
        #expect(rig.recorder.spawns.isEmpty, "the helper starts only once quit is committed")
        #expect(rig.recorder.terminations == 1)
    }

    @Test func installSpawnsOnlyWhenTheAppWillTerminate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try await rig.readyToInstall()
        rig.controller.installNow()
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns == [.init(archive: rig.cachedArchive(),
                                              target: rig.apps.appendingPathComponent("LoftLine.app").deletingLastPathComponent(),
                                              pid: ProcessInfo.processInfo.processIdentifier, relaunch: true, sha256: entry.sha256,
                                              version: entry.version)])
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.count == 1, "a second terminate notification does nothing")
    }

    @Test func installOnQuitWaitsForTheQuitAndDoesNotRelaunch() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        rig.controller.installOnQuit()
        #expect(rig.controller.state == .installPending(relaunch: false))
        #expect(rig.recorder.terminations == 0, "nothing quits the app for an install-on-quit")
        #expect(rig.recorder.spawns.isEmpty)
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.map(\.relaunch) == [false])
    }

    @Test func cancelledQuitKeepsThePendingInstall() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        rig.controller.installNow()
        // The user cancels at a save prompt: AppKit never calls applicationWillTerminate.
        #expect(rig.controller.state == .installPending(relaunch: true))
        #expect(rig.recorder.spawns.isEmpty)
        #expect(FileManager.default.fileExists(atPath: rig.cachedArchive().path), "the verified archive waits for the real quit")
    }

    @Test func aCachedArchiveChangedAfterVerificationIsNeverHandedToTheHelper() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try await rig.readyToInstall()
        rig.controller.installOnQuit()
        try Data("something else".utf8).write(to: rig.cachedArchive())
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.isEmpty, "the digest is checked again just before the helper starts")
        #expect(rig.cachedFiles() == [], "the changed file is removed")
    }

    @Test func nothingIsInstalledBeforeAVerifiedDownload() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try rig.serve()
        await rig.controller.checkNow(userInitiated: true)
        rig.controller.installNow()
        #expect(rig.controller.state == .available(entry), "an available update is not installable until it is downloaded")
        rig.controller.applicationWillTerminate()
        #expect(rig.recorder.spawns.isEmpty && rig.recorder.terminations == 0)
    }

    // MARK: what the windows read

    @Test func eachVersionIsAnnouncedOnce() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let entry = try rig.serve(version: "0.2.1")
        #expect(rig.controller.shouldPrompt(for: entry))
        rig.controller.markPrompted(entry)
        #expect(!rig.controller.shouldPrompt(for: entry))
        #expect(rig.store.lastPromptedVersion == "0.2.1")
        #expect(rig.controller.shouldPrompt(for: try rig.serve(version: "0.2.2")), "a newer version is a new announcement")
    }

    @Test func lastCheckIsPublishedAfterASuccessfulCheck() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        #expect(rig.controller.lastCheck == nil)
        try rig.serve()
        await rig.controller.checkNow(userInitiated: true)
        #expect(rig.controller.lastCheck == rig.clock)
        #expect(rig.controller.currentVersion == "0.2.0")
    }

    // MARK: how the helper is started

    @Test func theHelperIsStartedWithTheDigestAndAMinimalEnvironment() {
        let archive = URL(fileURLWithPath: "/Users/x/Library/Caches/LoftLine/Updates/LoftLine-0.2.1.zip")
        let args = UpdateController.helperArguments(archive: archive, target: URL(fileURLWithPath: "/Applications"), pid: 321,
                                                    relaunch: true, sha256: String(repeating: "ab", count: 32), version: "0.2.1")
        #expect(args == ["--archive", archive.path, "--sha256", String(repeating: "ab", count: 32), "--version", "0.2.1",
                         "--target", "/Applications", "--pid", "321", "--relaunch", "1"])
        let env = UpdateController.helperEnvironment()
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env.keys.allSatisfy { !$0.hasPrefix("LOFTLINE_") }, "test overrides in the app's environment must not reach the helper")
        #expect(env["LOFTLINE_UPDATER_SKIP_CODESIGN"] == nil)
    }

    @Test func startingTheHelperKeepsItsOutputAndItsTempCopyGoesAway() async throws {
        // The helper runs after the app has quit, so whatever it says is the only record of why an update did not happen.
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-starthelper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let resources = box.appendingPathComponent("Fake.app/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ScriptRunner.root.appendingPathComponent("packaging/updater/macos.sh"),
                                         to: resources.appendingPathComponent("updater.sh"))
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>x.fake</string></dict></plist>".utf8)
            .write(to: box.appendingPathComponent("Fake.app/Contents/Info.plist"))
        let temp = box.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let log = box.appendingPathComponent("logs/updater.log")

        let start = UpdateController.startHelper(from: try #require(Bundle(url: box.appendingPathComponent("Fake.app"))),
                                                 log: log, tempDirectory: temp)
        // An archive that is not there: the helper refuses at once, and says so.
        start(box.appendingPathComponent("missing.zip"), box, 1, false, String(repeating: "a", count: 64), "2.0.0")

        var written = ""
        for _ in 0..<100 where !written.contains("archive not found") {
            try await Task.sleep(nanoseconds: 100_000_000)
            written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }
        #expect(written.contains("archive not found"), "the helper's refusal reaches the log: \(written)")
        #expect(written.contains("2.0.0"), "the log says which update it was about: \(written)")
        var leftovers = ["pending"]
        for _ in 0..<100 where !leftovers.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        }
        #expect(leftovers.isEmpty, "the temp copy of the helper removes itself: \(leftovers)")
    }

    // MARK: bundle info and old-bundle cleanup

    @Test func bundleInfoReadsTheVersionAndChannelFromInfoPlist() throws {
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-bundleinfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        func bundle(_ name: String, _ plist: [String: Any]) throws -> Bundle {
            let contents = box.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return try #require(Bundle(url: box.appendingPathComponent("\(name).app")))
        }
        let release = BundleInfo(bundle: try bundle("A", ["CFBundleIdentifier": "x.a", "CFBundleShortVersionString": "0.2.1",
                                                          "LoftLineChannel": "release"]))
        #expect(release.version == "0.2.1" && release.channel == "release")
        let bare = BundleInfo(bundle: try bundle("B", ["CFBundleIdentifier": "x.b"]))
        #expect(bare.channel == "dev", "no channel key means a development build")
        #expect(bare.version == "0")
    }

    @Test func cleanupRemovesOnlyOldSiblings() throws {
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-cleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let fm = FileManager.default
        for name in ["LoftLine.app", "LoftLine.old-123", "LoftLine.old-4567", "LoftLine.old-backup", "LoftLine.old", "Other.old-5",
                     "LoftLine.old-"] {
            try fm.createDirectory(at: box.appendingPathComponent(name).appendingPathComponent("Contents"), withIntermediateDirectories: true)
        }
        UpdateCleanup.removeOldBundles(besides: box.appendingPathComponent("LoftLine.app"))
        let left = try fm.contentsOfDirectory(atPath: box.path).sorted()
        #expect(left == ["LoftLine.app", "LoftLine.old", "LoftLine.old-", "LoftLine.old-backup", "Other.old-5"],
                "only LoftLine.old-<pid> goes; a name a person gave a folder stays")
    }

    @Test func appPreferencesPersistAutoCheck() {
        let suite = "loftline-tests-autocheck-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppPreferences(defaults: defaults).autoCheckForUpdates, "on unless turned off")
        var prefs = AppPreferences()
        prefs.autoCheckForUpdates = false
        prefs.save(to: defaults)
        #expect(!AppPreferences(defaults: defaults).autoCheckForUpdates)
        #expect(defaults.object(forKey: "loftline.pref.autoCheckForUpdates") as? Bool == false)
    }
}
