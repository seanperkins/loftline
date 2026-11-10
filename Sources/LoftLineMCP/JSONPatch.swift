import Foundation

/// A JSON merge patch (RFC 7386): objects merge key by key, a JSON null removes the key, anything else replaces it.
enum JSONPatch {
    static func merge(_ patch: [String: Any], into base: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch {
            if value is NSNull {
                out[key] = nil
            } else if let child = value as? [String: Any], let existing = out[key] as? [String: Any] {
                out[key] = merge(child, into: existing)
            } else {
                out[key] = value
            }
        }
        return out
    }
}
