import Foundation

/// A PNG picture of the design embedded at the very start of each saved `.loftline` file, as the
/// top-level key `quickLookThumbnail` (base64), so the Quick Look thumbnail extension
/// (Extensions/QuickLookThumbnail, built by scripts/bundle.sh) can show it by reading only the
/// first bytes of the file, without LoftLine's model code. Readers of the project ignore the key.
///
/// Foundation only: this file is also compiled into the extension.
public enum QuickLookThumbnailData {
    public static let key = "quickLookThumbnail"
    /// The extension reads at most this many bytes from the start of the file.
    public static let headerLimit = 4 * 1024 * 1024

    /// `json` (a top-level JSON object) with the thumbnail inserted as its first member.
    public static func embed(_ png: Data, in json: Data) -> Data {
        guard let brace = json.firstIndex(of: UInt8(ascii: "{")) else { return json }
        var out = Data(json[..<json.index(after: brace)])
        out.append(Data("\n  \"\(key)\" : \"\(png.base64EncodedString())\",".utf8))
        // An empty object would leave a trailing comma; .loftline files never are, but stay valid.
        let rest = json[json.index(after: brace)...]
        if let next = rest.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), next == UInt8(ascii: "}") {
            out.removeLast()   // drop the comma
        }
        out.append(rest)
        return out
    }

    /// The embedded PNG, looked for in the first `headerLimit` bytes of `data`.
    public static func read(from data: Data) -> Data? {
        let head = data.prefix(headerLimit)
        let marker = Data("\"\(key)\"".utf8)
        guard let m = head.range(of: marker) else { return nil }
        var i = m.upperBound
        // Skip `<spaces> : <spaces> "`.
        while i < head.endIndex, head[i] == 0x20 || head[i] == 0x0A || head[i] == 0x09 || head[i] == 0x0D { i += 1 }
        guard i < head.endIndex, head[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        while i < head.endIndex, head[i] == 0x20 || head[i] == 0x0A || head[i] == 0x09 || head[i] == 0x0D { i += 1 }
        guard i < head.endIndex, head[i] == UInt8(ascii: "\"") else { return nil }
        let start = head.index(after: i)
        guard let end = head[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        // JSONEncoder may escape "/" as "\/" in base64; undo it.
        let b64 = String(decoding: head[start..<end], as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        return Data(base64Encoded: b64)
    }

    public static func read(from url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: headerLimit) else { return nil }
        return read(from: head)
    }
}
