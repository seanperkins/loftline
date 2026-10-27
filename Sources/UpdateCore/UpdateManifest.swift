import Foundation

/// One platform's entry of the update feed, already checked field by field.
public struct UpdateEntry: Equatable, Sendable {
    public let version: String
    public let url: URL
    /// 64 lowercase hex characters: the SHA-256 of the archive.
    public let sha256: String
    /// The RSA-4096 signature over the archive (decoded from base64).
    public let signature: Data
    public let gcodeChanged: Bool
    public let notes: String

    public init(version: String, url: URL, sha256: String, signature: Data, gcodeChanged: Bool, notes: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.signature = signature
        self.gcodeChanged = gcodeChanged
        self.notes = notes
    }
}

/// Parses and validates `latest.json`. Any violation refuses the whole entry: nothing is clamped or repaired.
public enum UpdateManifest {
    public static let platformKey = "macos-arm64"
    public static let urlPrefix = "https://github.com/seanperkins/loftline/releases/download/"

    static let maxDocumentBytes = 256 * 1024
    static let maxVersionCharacters = 32
    static let maxNotesCharacters = 4000
    /// An RSA-4096 signature is 512 bytes.
    static let signatureBytes = 512

    public static func parse(_ data: Data, platform: String = platformKey) -> UpdateEntry? {
        guard data.count <= maxDocumentBytes,
              let feed = try? JSONDecoder().decode(Feed.self, from: data),
              let raw = feed.entries[platform]?.value,
              isValidVersion(raw.version),
              let url = validatedURL(raw.url),
              isLowercaseHex64(raw.sha256),
              let signature = Data(base64Encoded: raw.sig), signature.count == signatureBytes
        else { return nil }
        let notes = raw.notes ?? ""
        guard notes.count <= maxNotesCharacters else { return nil }
        return UpdateEntry(version: raw.version, url: url, sha256: raw.sha256, signature: signature,
                           gcodeChanged: raw.gcodeChanged ?? false, notes: notes)
    }

    /// The version names the downloaded file, so it holds only version characters and starts with a digit.
    private static func isValidVersion(_ version: String) -> Bool {
        guard let first = version.first, first.isASCII, first.isNumber, version.count <= maxVersionCharacters else { return false }
        return version.allSatisfy { isSafePathCharacter($0) || $0 == "+" }
    }

    /// `urlPrefix` followed by exactly `<tag>/<asset>`, each made of letters, digits, `.`, `_` and `-` and neither `.` nor `..`.
    /// That rules out a query, a fragment, credentials, percent-escapes and dot segments that would leave the download folder.
    private static func validatedURL(_ text: String) -> URL? {
        guard text.hasPrefix(urlPrefix) else { return nil }
        let segments = text.dropFirst(urlPrefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(isSafePathCharacter) })
        else { return nil }
        return URL(string: text)
    }

    private static func isSafePathCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
    }

    private static func isLowercaseHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // MARK: Wire format

    private struct Feed: Decodable {
        let entries: [String: Lenient<Raw>]
    }

    private struct Raw: Decodable {
        let version: String
        let url: String
        let sha256: String
        let sig: String
        let gcodeChanged: Bool?
        let notes: String?
    }

    /// An entry for another platform that does not decode must not block ours.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}
