import Combine
import Foundation
import UpdateCore
import os

/// What the controller needs to know about the running app.
struct BundleInfo: Equatable {
    var version: String
    var channel: String
    var bundleURL: URL

    init(version: String, channel: String, bundleURL: URL) {
        self.version = version
        self.channel = channel
        self.bundleURL = bundleURL
    }

    /// From Info.plist: `CFBundleShortVersionString` and `LoftLineChannel` (scripts/bundle.sh writes it). A build without the
    /// key is a development build.
    init(bundle: Bundle = .main) {
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        channel = bundle.object(forInfoDictionaryKey: "LoftLineChannel") as? String ?? "dev"
        bundleURL = bundle.bundleURL
    }
}

/// Finds, downloads and verifies a newer release, and hands the install to the helper once the app is really quitting.
///
/// The one rule that matters: nothing is executed or handed on unless its SHA-256 matches the feed and the feed's RSA signature
/// verifies against the key built into the app. The helper is started only from `applicationWillTerminate`, never mid-session.
@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateEntry)
        case downloading
        case readyToInstall(UpdateEntry)
        case installPending(relaunch: Bool)
        case failed(String)
    }

    static let defaultFeedURL = URL(string: "https://github.com/seanperkins/loftline/releases/latest/download/latest.json")!
    /// Honoured only on the `dev` channel.
    static let feedOverrideVariable = "LOFTLINE_UPDATE_FEED_URL"
    /// `1` turns every check off (tests, the UI harness, CI).
    static let disableVariable = "LOFTLINE_NO_UPDATE_CHECK"
    static let minimumAutomaticInterval: TimeInterval = 24 * 3600
    static let maxFeedBytes = 256 * 1024
    static let maxArchiveBytes: Int64 = 512 * 1024 * 1024

    private static let log = Logger(subsystem: "com.seanperkins.loftline", category: "updates")

    @Published private(set) var state: State = .idle

    private struct Pending {
        var entry: UpdateEntry
        var archive: URL
        var relaunch: Bool
    }
    private struct Failure: Error { var message: String }

    private let session: URLSession
    private let store: UpdateStateStore
    private let bundle: BundleInfo
    private let publicKeyPEM: String
    private let cacheDirectory: URL
    private let autoCheckEnabled: () -> Bool
    private let spawnHelper: (_ archive: URL, _ target: URL, _ pid: Int32, _ relaunch: Bool, _ sha256: String) -> Void
    private let terminate: () -> Void
    private let environment: [String: String]
    private let now: () -> Date
    private var pending: Pending?
    private var spawned = false

    init(session: URLSession, store: UpdateStateStore, bundle: BundleInfo, publicKeyPEM: String, cacheDirectory: URL,
         autoCheckEnabled: @escaping () -> Bool,
         spawnHelper: @escaping (_ archive: URL, _ target: URL, _ pid: Int32, _ relaunch: Bool, _ sha256: String) -> Void,
         terminate: @escaping () -> Void,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.store = store
        self.bundle = bundle
        self.publicKeyPEM = publicKeyPEM
        self.cacheDirectory = cacheDirectory
        self.autoCheckEnabled = autoCheckEnabled
        self.spawnHelper = spawnHelper
        self.terminate = terminate
        self.environment = environment
        self.now = now
    }

    /// Release builds, with the preference on and the environment not silenced.
    var canAutoCheck: Bool {
        bundle.channel == "release" && autoCheckEnabled() && environment[Self.disableVariable] != "1"
    }

    /// The feed to read: the override only on a `dev` build, so a release build can never be pointed elsewhere.
    var feedURL: URL {
        if bundle.channel == "dev", let text = environment[Self.feedOverrideVariable], let url = URL(string: text), url.scheme != nil {
            return url
        }
        return Self.defaultFeedURL
    }

    // MARK: Checking

    func checkNow(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .readyToInstall, .installPending: return
        default: break
        }
        if environment[Self.disableVariable] == "1" {
            if userInitiated { state = .failed("Update checks are turned off in this environment.") }
            return
        }
        if bundle.channel != "release" {
            // Development and rehearsal builds never check on their own. Asking by hand says why, unless a dev build was given
            // a feed to test against.
            guard userInitiated else { return }
            guard bundle.channel == "dev", feedURL != Self.defaultFeedURL else {
                state = .failed(bundle.channel == "dev" ? "Development builds do not update." : "Rehearsal builds do not update.")
                return
            }
        } else if !userInitiated {
            guard canAutoCheck else { return }
            if let last = store.lastCheck, now().timeIntervalSince(last) < Self.minimumAutomaticInterval { return }
        }

        let previous = state
        state = .checking
        do {
            let data = try await fetch(feedURL, limit: Self.maxFeedBytes)
            guard let entry = UpdateManifest.parse(data) else { throw Failure(message: "The update feed could not be read.") }
            store.lastCheck = now()
            if !UpdateVersion.isNewer(entry.version, than: bundle.version) {
                state = .upToDate
            } else if !userInitiated, store.skippedVersion == entry.version {
                state = .upToDate
            } else {
                state = .available(entry)
            }
        } catch {
            let message = Self.message(for: error)
            if userInitiated {
                state = .failed(message)
            } else {
                Self.log.error("automatic update check failed: \(message, privacy: .public)")
                state = previous == .checking ? .idle : previous
            }
        }
    }

    // MARK: Downloading

    /// `available` -> `readyToInstall`, or `failed` with nothing unverified left on disk.
    func download() async {
        guard case .available(let entry) = state else { return }
        state = .downloading
        let fm = FileManager.default
        var downloaded: URL?
        defer { if let downloaded { try? fm.removeItem(at: downloaded) } }
        do {
            let (file, response) = try await session.download(for: request(for: entry.url))
            downloaded = file
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure(message: "The update server answered with an error.")
            }
            let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= Self.maxArchiveBytes else { throw Failure(message: "The download has an unexpected size and was deleted.") }
            let digest = try UpdateSignature.sha256Hex(of: file)
            guard digest == entry.sha256 else { throw Failure(message: "The download did not match its checksum and was deleted.") }
            guard UpdateSignature.verify(digestHex: digest, signature: entry.signature, publicKeyPEM: publicKeyPEM) else {
                throw Failure(message: "The download's signature is not valid, so it was deleted.")
            }
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let destination = archiveURL(for: entry)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: file, to: destination)
            downloaded = nil
            removeOtherCachedArchives(keeping: destination)
            state = .readyToInstall(entry)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    // MARK: Installing

    /// "Install and Restart": quit now; the helper starts once the quit is committed.
    func installNow() { beginInstall(relaunch: true) }

    /// "Install when I quit": nothing happens until the app quits on its own.
    func installOnQuit() { beginInstall(relaunch: false) }

    func skipVersion() {
        switch state {
        case .available(let entry), .readyToInstall(let entry):
            store.skippedVersion = entry.version
            try? FileManager.default.removeItem(at: archiveURL(for: entry))
            state = .idle
        default:
            break
        }
    }

    /// The only place the helper is started: AppKit calls this once a quit can no longer be cancelled (a save prompt that was
    /// cancelled never gets here, so the install stays pending for the real quit).
    func applicationWillTerminate() {
        guard let pending, !spawned else { return }
        spawned = true
        // The digest is checked again here: the file has sat in the cache since it was verified.
        guard (try? UpdateSignature.sha256Hex(of: pending.archive)) == pending.entry.sha256 else {
            Self.log.error("the cached update changed after it was verified; not installing")
            try? FileManager.default.removeItem(at: pending.archive)
            return
        }
        spawnHelper(pending.archive, bundle.bundleURL.deletingLastPathComponent(), ProcessInfo.processInfo.processIdentifier,
                    pending.relaunch, pending.entry.sha256)
    }

    private func beginInstall(relaunch: Bool) {
        let entry: UpdateEntry
        switch state {
        case .readyToInstall(let ready): entry = ready
        case .installPending:
            guard let current = pending else { return }
            entry = current.entry
        default: return
        }
        if let problem = installProblem() {
            state = .failed(problem)
            return
        }
        pending = Pending(entry: entry, archive: archiveURL(for: entry), relaunch: relaunch)
        state = .installPending(relaunch: relaunch)
        if relaunch { terminate() }
    }

    private func installProblem() -> String? {
        if bundle.channel != "release" { return "Development builds do not install updates." }
        if bundle.bundleURL.path.contains("/AppTranslocation/") { return "Move LoftLine to Applications first" }
        guard bundle.bundleURL.pathExtension == "app" else {
            return "LoftLine can only update an installed app. Move LoftLine to your Applications folder first."
        }
        if !FileManager.default.isWritableFile(atPath: bundle.bundleURL.deletingLastPathComponent().path) {
            return "LoftLine cannot be updated here because its folder is not writable. Move LoftLine to your Applications folder."
        }
        return nil
    }

    // MARK: Helper launch

    static func helperArguments(archive: URL, target: URL, pid: Int32, relaunch: Bool, sha256: String) -> [String] {
        ["--archive", archive.path, "--sha256", sha256, "--target", target.path, "--pid", String(pid),
         "--relaunch", relaunch ? "1" : "0"]
    }

    /// A fixed, minimal environment. The app's own environment is never passed on, so the helper's test-only switches
    /// (`LOFTLINE_UPDATER_*`) cannot reach a real install from here.
    static func helperEnvironment() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
    }

    /// The production `spawnHelper`: copies `Contents/Resources/updater.sh` out of the bundle (the bundle is about to be
    /// replaced) and starts that copy with `/bin/bash`, detached, with no standard streams. Nothing is waited for.
    static func startHelper(from bundle: Bundle = .main)
        -> (_ archive: URL, _ target: URL, _ pid: Int32, _ relaunch: Bool, _ sha256: String) -> Void {
        { archive, target, pid, relaunch, sha256 in
            guard let source = bundle.url(forResource: "updater", withExtension: "sh") else {
                log.error("the bundle has no updater.sh; not installing")
                return
            }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-updater-\(UUID().uuidString).sh")
            do {
                try FileManager.default.copyItem(at: source, to: copy)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copy.path)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [copy.path] + helperArguments(archive: archive, target: target, pid: pid,
                                                                  relaunch: relaunch, sha256: sha256)
                process.environment = helperEnvironment()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
            } catch {
                log.error("could not start the update helper: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Plumbing

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("LoftLine/\(bundle.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The body of a 200 response, refused as soon as it passes `limit` bytes.
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request(for: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "The update server answered with an error.")
        }
        guard http.expectedContentLength <= Int64(limit) else { throw Failure(message: "The update feed is too large.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw Failure(message: "The update feed is too large.") }
        }
        return data
    }

    private func archiveURL(for entry: UpdateEntry) -> URL {
        cacheDirectory.appendingPathComponent("LoftLine-\(entry.version).zip")
    }

    private func removeOtherCachedArchives(keeping kept: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? [] where name.hasPrefix("LoftLine-") && name.hasSuffix(".zip") {
            let url = cacheDirectory.appendingPathComponent(name)
            if url.lastPathComponent != kept.lastPathComponent { try? fm.removeItem(at: url) }
        }
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if error is URLError { return "LoftLine could not reach the update server." }
        return "The update failed: \(error.localizedDescription)"
    }
}
