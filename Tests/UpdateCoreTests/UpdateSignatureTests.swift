import Foundation
import Testing
import UpdateCore

/// Runs a program with stdout and stderr merged. Inherited signing and git variables are dropped so a developer's own keys
/// and git config never reach the script under test.
private enum Sh {
    struct Output { var status: Int32; var text: String }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, env: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UPDATE_SIGN") && !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment.merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }
}

/// Test-only material, generated once per run in a temp folder. No key is committed, so nothing here can be mistaken for the
/// production key, and no file has a credential-looking name.
private enum Fixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = root.appendingPathComponent("scripts/update-feed.sh").path

    static let dir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loftline-update-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func makeKey(_ name: String) -> URL {
        let file = dir.appendingPathComponent("\(name).dat")
        let result = try! Sh.run("/usr/bin/openssl", ["genrsa", "-out", file.path, "4096"])
        precondition(result.status == 0, result.text)
        return file
    }

    /// The PKCS#1 `RSA PUBLIC KEY` PEM of a private key file.
    static func publicPEM(of key: URL) -> String {
        let out = dir.appendingPathComponent("\(key.lastPathComponent).pub")
        let result = try! Sh.run("/usr/bin/openssl", ["rsa", "-in", key.path, "-RSAPublicKey_out", "-out", out.path])
        precondition(result.status == 0, result.text)
        return try! String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let key = makeKey("signer")
    static let otherKey = makeKey("other")
    static let publicKey = publicPEM(of: key)
    static let otherPublicKey = publicPEM(of: otherKey)

    /// A few MiB of fixed bytes, so the streamed hash crosses chunk boundaries.
    static func archive(flipByteAt index: Int? = nil) -> URL {
        var bytes = (0..<(3 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        if let index { bytes[index] ^= 0x01 }
        let file = dir.appendingPathComponent("archive-\(index.map(String.init) ?? "original").zip")
        try! Data(bytes).write(to: file)
        return file
    }
    static let zip = archive()

    /// Runs the real script for `tag` with the test key and parses its feed.
    static func feed(tag: String = "v9.9.9", zip: URL = Fixture.zip, notes: String? = nil, cwd: URL? = nil) throws -> (UpdateEntry?, Sh.Output) {
        let out = dir.appendingPathComponent("latest-\(UUID().uuidString).json")
        var arguments = [tag, "--zip", zip.path, "--out", out.path]
        if let notes {
            let file = dir.appendingPathComponent("notes-\(UUID().uuidString).md")
            try notes.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--notes", file.path]
        }
        let result = try Sh.run(script, arguments, cwd: cwd ?? root, env: ["UPDATE_SIGN_KEY_FILE": key.path])
        guard result.status == 0, let data = try? Data(contentsOf: out) else { return (nil, result) }
        return (UpdateManifest.parse(data), result)
    }
}

@Suite struct UpdateSignatureTests {
    @Test func signatureFromTheScriptVerifies() throws {
        let (entry, result) = try Fixture.feed()
        let parsed = try #require(entry, "\(result.text)")
        #expect(UpdateSignature.verify(digestHex: parsed.sha256, signature: parsed.signature, publicKeyPEM: Fixture.publicKey))
        #expect(parsed.url.absoluteString == "https://github.com/seanperkins/loftline/releases/download/v9.9.9/LoftLine-v9.9.9-macos-arm64.zip")
        #expect(parsed.version == "9.9.9")
    }

    @Test func oneFlippedByteFails() throws {
        let (entry, _) = try Fixture.feed()
        let parsed = try #require(entry)
        // The archive in a hostile cache differs by one bit from the one that was signed.
        let tampered = try UpdateSignature.sha256Hex(of: Fixture.archive(flipByteAt: 1_500_000))
        #expect(tampered != parsed.sha256)
        #expect(!UpdateSignature.verify(digestHex: tampered, signature: parsed.signature, publicKeyPEM: Fixture.publicKey))
    }

    @Test func aSignatureFromAnotherKeyFails() throws {
        let (entry, _) = try Fixture.feed()
        let parsed = try #require(entry)
        #expect(!UpdateSignature.verify(digestHex: parsed.sha256, signature: parsed.signature, publicKeyPEM: Fixture.otherPublicKey))
    }

    @Test func sha256HexMatchesOpenssl() throws {
        let reference = try Sh.run("/usr/bin/openssl", ["dgst", "-sha256", Fixture.zip.path])
        let expected = try #require(reference.text.split(separator: " ").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        #expect(try UpdateSignature.sha256Hex(of: Fixture.zip) == expected)
        #expect(expected.count == 64 && expected == expected.lowercased())
    }

    @Test func manifestShaMatchesTheFile() throws {
        let (entry, _) = try Fixture.feed()
        #expect(try #require(entry).sha256 == UpdateSignature.sha256Hex(of: Fixture.zip))
    }

    @Test func sha256HexOfAMissingFileThrows() {
        #expect(throws: (any Error).self) { try UpdateSignature.sha256Hex(of: Fixture.dir.appendingPathComponent("none.zip")) }
    }

    @Test func refusesAPublicKeyThatIsNotPKCS1RSA4096() throws {
        let (entry, _) = try Fixture.feed()
        let parsed = try #require(entry)
        for bad in ["", "not a key", "-----BEGIN RSA PUBLIC KEY-----\nAAAA\n-----END RSA PUBLIC KEY-----",
                    "-----BEGIN PUBLIC KEY-----\n\(Data(repeating: 1, count: 64).base64EncodedString())\n-----END PUBLIC KEY-----"] {
            #expect(!UpdateSignature.verify(digestHex: parsed.sha256, signature: parsed.signature, publicKeyPEM: bad), "\(bad.prefix(40))")
        }
    }

    @Test func refusesADigestThatIsNotSha256Hex() throws {
        let (entry, _) = try Fixture.feed()
        let parsed = try #require(entry)
        for bad in ["", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 63), parsed.sha256.uppercased()] {
            #expect(!UpdateSignature.verify(digestHex: bad, signature: parsed.signature, publicKeyPEM: Fixture.publicKey), "\(bad.count)")
        }
    }

    @Test func productionKeyMatchesTheCommittedPem() throws {
        let committed = try String(contentsOf: Fixture.root.appendingPathComponent("packaging/updater/update-public-key.pub"), encoding: .utf8)
        #expect(UpdateSignature.publicKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
                == committed.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(UpdateSignature.publicKeyPEM.contains("BEGIN RSA PUBLIC KEY"))
    }

    // MARK: scripts/update-feed.sh

    @Test func noPreviousTagMeansGcodeUnchanged() throws {
        let repo = try Self.repo()
        try Self.commit(repo, "samples/expected/a.nc", "G0 X0\n", message: "first")
        let (entry, result) = try Fixture.feed(tag: "v1.0.0", cwd: repo)
        #expect(try #require(entry, "\(result.text)").gcodeChanged == false)
    }

    @Test func gcodeChangedIsTrueOnlyWhenTheExpectedProgramsDifferBetweenTags() throws {
        let repo = try Self.repo()
        try Self.commit(repo, "samples/expected/a.nc", "G0 X0\n", message: "first")
        try Self.git(repo, "tag", "v1.0.0")
        try Self.commit(repo, "samples/expected/a.nc", "G0 X1\n", message: "post output changes")
        try Self.git(repo, "tag", "v1.0.1")
        try Self.commit(repo, "README.md", "notes\n", message: "docs only")
        try Self.git(repo, "tag", "v1.0.2")
        try Self.commit(repo, "Tests/Fixtures/golden/g.tap", "G1\n", message: "a golden changes")
        try Self.git(repo, "tag", "v1.0.3")
        #expect(try #require(Fixture.feed(tag: "v1.0.1", cwd: repo).0).gcodeChanged == true)
        #expect(try #require(Fixture.feed(tag: "v1.0.2", cwd: repo).0).gcodeChanged == false)
        #expect(try #require(Fixture.feed(tag: "v1.0.3", cwd: repo).0).gcodeChanged == true)
    }

    @Test func gcodeChangedInNamesTheLatestOutputChangeSoASkippedReleaseStillWarns() throws {
        // 0.0.1 changes the post output, 0.0.2 and 0.0.3 do not: someone updating from 1.0.0 straight to 1.0.3 passes the
        // change, and `gcodeChanged` (this release against the one before it) is false for 1.0.3.
        let repo = try Self.repo()
        try Self.commit(repo, "samples/expected/a.nc", "G0 X0\n", message: "first")
        try Self.git(repo, "tag", "v1.0.0")
        try Self.commit(repo, "samples/expected/a.nc", "G0 X1\n", message: "post output changes")
        try Self.git(repo, "tag", "v1.0.1")
        try Self.commit(repo, "README.md", "one\n", message: "docs")
        try Self.git(repo, "tag", "v1.0.2")
        try Self.commit(repo, "README.md", "two\n", message: "docs again")
        try Self.git(repo, "tag", "v1.0.3")
        try Self.commit(repo, "Tests/Fixtures/golden/g.tap", "G1\n", message: "a golden changes later")
        try Self.git(repo, "tag", "v1.0.4")

        let skipped = try #require(Fixture.feed(tag: "v1.0.3", cwd: repo).0)
        #expect(skipped.gcodeChanged == false)
        #expect(skipped.gcodeChangedIn == "1.0.1", "later releases do not count towards an earlier one")
        let changing = try #require(Fixture.feed(tag: "v1.0.1", cwd: repo).0)
        #expect(changing.gcodeChanged == true)
        #expect(changing.gcodeChangedIn == "1.0.1")
        #expect(try #require(Fixture.feed(tag: "v1.0.4", cwd: repo).0).gcodeChangedIn == "1.0.4")
        #expect(try #require(Fixture.feed(tag: "v1.0.0", cwd: repo).0).gcodeChangedIn == nil, "the first release has nothing to compare with")
    }

    @Test func tagsAreOrderedByVersionNotByName() throws {
        // v1.0.10 sorts before v1.0.9 as text. Its predecessor is v1.0.9, and that is the diff that counts.
        let repo = try Self.repo()
        try Self.commit(repo, "samples/expected/a.nc", "G0 X0\n", message: "first")
        try Self.git(repo, "tag", "v1.0.8")
        try Self.commit(repo, "README.md", "x\n", message: "docs")
        try Self.git(repo, "tag", "v1.0.9")
        try Self.commit(repo, "samples/expected/a.nc", "G0 X9\n", message: "post output changes")
        try Self.git(repo, "tag", "v1.0.10")
        let entry = try #require(Fixture.feed(tag: "v1.0.10", cwd: repo).0)
        #expect(entry.gcodeChanged == true)
        #expect(entry.gcodeChangedIn == "1.0.10")
        #expect(try #require(Fixture.feed(tag: "v1.0.9", cwd: repo).0).gcodeChangedIn == nil)
    }

    @Test func noOutputChangeEverMeansNoGcodeChangedIn() throws {
        let repo = try Self.repo()
        try Self.commit(repo, "samples/expected/a.nc", "G0 X0\n", message: "first")
        try Self.git(repo, "tag", "v1.0.0")
        try Self.commit(repo, "README.md", "docs\n", message: "docs")
        try Self.git(repo, "tag", "v1.0.1")
        let entry = try #require(Fixture.feed(tag: "v1.0.1", cwd: repo).0)
        #expect(entry.gcodeChanged == false)
        #expect(entry.gcodeChangedIn == nil)
    }

    @Test func notesAreCutAt4000CharactersAndStillParse() throws {
        let (entry, result) = try Fixture.feed(notes: String(repeating: "é", count: 5000))
        let parsed = try #require(entry, "\(result.text)")
        #expect(parsed.notes.count == 4000)
    }

    @Test func refusesATagThatIsNotAVersion() throws {
        for tag in ["latest", "1.2.3", "v1.2", "v1.2.3-rc1", "v1.2.3/../x"] {
            let result = try Sh.run(Fixture.script, [tag, "--zip", Fixture.zip.path, "--out", Fixture.dir.appendingPathComponent("x.json").path],
                                    env: ["UPDATE_SIGN_KEY_FILE": Fixture.key.path])
            #expect(result.status != 0, "\(tag)")
        }
    }

    @Test func refusesAMissingKeyAndAMissingArchive() throws {
        let noKey = try Sh.run(Fixture.script, ["v1.0.0", "--zip", Fixture.zip.path, "--out", Fixture.dir.appendingPathComponent("x.json").path],
                               env: ["UPDATE_SIGN_KEY_FILE": Fixture.dir.appendingPathComponent("absent.dat").path])
        #expect(noKey.status != 0)
        #expect(noKey.text.contains("genkey"), "\(noKey.text)")
        let noZip = try Sh.run(Fixture.script, ["v1.0.0", "--zip", Fixture.dir.appendingPathComponent("absent.zip").path,
                                                "--out", Fixture.dir.appendingPathComponent("x.json").path],
                               env: ["UPDATE_SIGN_KEY_FILE": Fixture.key.path])
        #expect(noZip.status != 0)
    }

    @Test func genkeyWritesAPrivateKeyAndPrintsOnlyThePublicOne() throws {
        let key = Fixture.dir.appendingPathComponent("genkey-\(UUID().uuidString).dat")
        let result = try Sh.run(Fixture.script, ["genkey"], env: ["UPDATE_SIGN_KEY_FILE": key.path])
        #expect(result.status == 0, "\(result.text)")
        #expect(result.text.contains("-----BEGIN RSA PUBLIC KEY-----"))
        #expect(!result.text.contains("PRIVATE"))
        let private_ = try String(contentsOf: key, encoding: .utf8)
        let body = try #require(private_.split(separator: "\n").dropFirst().first.map(String.init))
        #expect(!result.text.contains(body), "no part of the private key may be printed")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0, "the private key is for its owner only")
        // A second run never replaces the key, and still prints the same public key.
        let before = try Data(contentsOf: key)
        let again = try Sh.run(Fixture.script, ["genkey"], env: ["UPDATE_SIGN_KEY_FILE": key.path])
        #expect(again.status == 0)
        #expect(try Data(contentsOf: key) == before)
        #expect(again.text.contains("not overwriting"))
        #expect(again.text.contains("-----BEGIN RSA PUBLIC KEY-----"))
    }

    // MARK: temp git repositories

    static func git(_ repo: URL, _ arguments: String...) throws {
        let result = try Sh.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false",
                                                 "-c", "tag.gpgsign=false"] + arguments, cwd: repo)
        #expect(result.status == 0, "git \(arguments): \(result.text)")
    }

    static func repo() throws -> URL {
        let repo = Fixture.dir.appendingPathComponent("repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        return repo
    }

    static func commit(_ repo: URL, _ path: String, _ content: String, message: String) throws {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try git(repo, "add", "-A")
        try git(repo, "commit", "-q", "-m", message)
    }
}
