import Foundation
import Testing
import UpdateCore

@Suite struct UpdateManifestTests {
    static let goodURL = "https://github.com/seanperkins/loftline/releases/download/v0.2.1/LoftLine-v0.2.1-macos-arm64.zip"
    static let goodSHA = String(repeating: "ab", count: 32)
    static let goodSignature = Data(repeating: 7, count: 512).base64EncodedString()

    /// The feed document. `changes` replace fields of the entry; a nil value removes the field.
    static func feed(_ changes: [String: Any?] = [:], platform: String = UpdateManifest.platformKey) -> Data {
        var entry: [String: Any] = ["version": "0.2.1", "url": goodURL, "sha256": goodSHA, "sig": goodSignature,
                                    "gcodeChanged": false, "notes": "Fixes."]
        for (key, value) in changes { entry[key] = value }
        return try! JSONSerialization.data(withJSONObject: ["version": "0.2.1", "entries": [platform: entry]])
    }

    static func parse(_ changes: [String: Any?] = [:]) -> UpdateEntry? { UpdateManifest.parse(feed(changes)) }

    @Test func parsesAValidEntry() throws {
        let entry = try #require(Self.parse())
        #expect(entry.version == "0.2.1")
        #expect(entry.url.absoluteString == Self.goodURL)
        #expect(entry.sha256 == Self.goodSHA)
        #expect(entry.signature == Data(repeating: 7, count: 512))
        #expect(!entry.gcodeChanged)
        #expect(entry.notes == "Fixes.")
    }

    @Test func gcodeChangedAndNotesAreOptional() throws {
        let entry = try #require(Self.parse(["gcodeChanged": nil, "notes": nil]))
        #expect(!entry.gcodeChanged)
        #expect(entry.notes == "")
        #expect(try #require(Self.parse(["gcodeChanged": true])).gcodeChanged)
    }

    @Test func refusesAWrongHost() {
        #expect(Self.parse(["url": "https://evil.example/seanperkins/loftline/releases/download/v1/x.zip"]) == nil)
        #expect(Self.parse(["url": "https://github.com.evil.example/seanperkins/loftline/releases/download/v1/x.zip"]) == nil)
    }

    @Test func refusesAnotherRepository() {
        #expect(Self.parse(["url": "https://github.com/someone/else/releases/download/v1/x.zip"]) == nil)
    }

    @Test func refusesHttp() {
        #expect(Self.parse(["url": "http://github.com/seanperkins/loftline/releases/download/v1/x.zip"]) == nil)
    }

    @Test func refusesAUrlPrefixLookalike() {
        #expect(Self.parse(["url": "https://github.com/seanperkins/loftline/releases/download.evil.com/x"]) == nil)
    }

    @Test func refusesPathsThatLeaveTheDownloadFolder() {
        let base = UpdateManifest.urlPrefix
        for tail in ["../../../attacker/repo/releases/download/v1/x.zip", "v1/..", "./x.zip", "%2e%2e/x.zip", "v1/x.zip/extra",
                     "v1", "v1/", "/x.zip", "v1/x.zip?token=1", "v1/x.zip#frag", "v1/x@evil.zip", "v1/x y.zip"] {
            #expect(Self.parse(["url": base + tail]) == nil, "\(tail)")
        }
        #expect(Self.parse(["url": base + "v1.2.3/LoftLine-v1.2.3-macos-arm64.zip"]) != nil)
    }

    @Test func refusesShortOrUppercaseHex() {
        for bad in [String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "AB", count: 32),
                    String(repeating: "g", count: 64), ""] {
            #expect(Self.parse(["sha256": bad]) == nil, "\(bad.count) characters")
        }
    }

    @Test func refusesAMissingOrEmptySignature() {
        #expect(Self.parse(["sig": nil]) == nil)
        #expect(Self.parse(["sig": ""]) == nil)
    }

    @Test func refusesNonBase64Signature() {
        #expect(Self.parse(["sig": "not base64 !!"]) == nil)
    }

    @Test func refusesASignatureThatIsNotRSA4096Sized() {
        #expect(Self.parse(["sig": Data(repeating: 7, count: 256).base64EncodedString()]) == nil)
        #expect(Self.parse(["sig": Data(repeating: 7, count: 513).base64EncodedString()]) == nil)
    }

    @Test func refusesAVersionOver32Characters() {
        #expect(Self.parse(["version": String(repeating: "1", count: 32)]) != nil)
        #expect(Self.parse(["version": String(repeating: "1", count: 33)]) == nil)
    }

    @Test func refusesAVersionThatCouldEscapeTheCacheFolder() {
        // The version names the downloaded file (LoftLine-<version>.zip), so it may hold only version characters.
        for bad in ["../1", "1/2", "1 2", "", "v1\n", "1.0\u{0}", "-1", "1;rm"] {
            #expect(Self.parse(["version": bad]) == nil, "\(bad.debugDescription)")
        }
        #expect(Self.parse(["version": "0.4.0-rc.1+b5"]) != nil)
    }

    @Test func refusesNotesOver4000Characters() {
        #expect(Self.parse(["notes": String(repeating: "n", count: 4000)]) != nil)
        #expect(Self.parse(["notes": String(repeating: "n", count: 4001)]) == nil)
    }

    @Test func refusesAMissingPlatformEntry() {
        #expect(UpdateManifest.parse(Self.feed(platform: "windows-x64")) == nil)
        #expect(UpdateManifest.parse(Self.feed(platform: "windows-x64"), platform: "windows-x64") != nil)
    }

    @Test func aMalformedEntryForAnotherPlatformDoesNotBlockOurs() throws {
        let document: [String: Any] = ["entries": ["macos-arm64": ["version": "0.2.1", "url": Self.goodURL, "sha256": Self.goodSHA,
                                                                  "sig": Self.goodSignature],
                                                  "linux-x64": ["version": 5]]]
        let data = try JSONSerialization.data(withJSONObject: document)
        #expect(UpdateManifest.parse(data) != nil)
    }

    @Test func refusesNonJSONAndTheWrongShape() throws {
        #expect(UpdateManifest.parse(Data("not json".utf8)) == nil)
        #expect(UpdateManifest.parse(Data()) == nil)
        #expect(UpdateManifest.parse(Data("[]".utf8)) == nil)
        #expect(UpdateManifest.parse(try JSONSerialization.data(withJSONObject: ["version": "1"])) == nil)
        #expect(UpdateManifest.parse(try JSONSerialization.data(withJSONObject: ["entries": []])) == nil)
    }

    @Test func refusesWrongTypes() {
        #expect(Self.parse(["sha256": 12345]) == nil)
        #expect(Self.parse(["version": 2]) == nil)
        #expect(Self.parse(["url": 5]) == nil)
        #expect(Self.parse(["sig": 5]) == nil)
        #expect(Self.parse(["notes": 5]) == nil)
        #expect(Self.parse(["gcodeChanged": 1]) == nil)
        #expect(Self.parse(["gcodeChanged": "yes"]) == nil)
    }

    @Test func refusesAnOversizedDocument() throws {
        var data = Self.feed()
        data.append(Data(repeating: 0x20, count: 300 * 1024))
        #expect(UpdateManifest.parse(data) == nil)
    }
}
