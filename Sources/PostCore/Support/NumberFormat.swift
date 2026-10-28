import Foundation

/// Deterministic, locale-independent number formatting for G-code words.
enum NumberFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Fixed `decimals` places; never emits "-0.000".
    static func fixed(_ value: Double, decimals: Int) -> String {
        let d = max(0, decimals)
        var s = String(format: "%.\(d)f", locale: posix, value)
        if s.hasPrefix("-"), s.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) { s.removeFirst() }
        return s
    }

    /// Rounded down to `decimals` places, for values that must not round up past a limit (a probe's feed and travel).
    /// The small epsilon keeps a value that is exact in decimal but not in binary (25.4 mm / 25.4 = 0.99999...) whole.
    static func floored(_ value: Double, decimals: Int) -> String {
        let scale = pow(10, Double(max(0, decimals)))
        return fixed((value * scale + 1e-9).rounded(.down) / scale, decimals: decimals)
    }

    /// Rounded toward zero, so a machine position on the envelope's edge never lands a digit beyond it.
    static func towardZero(_ value: Double, decimals: Int) -> String {
        value < 0 ? fixed(-Double(floored(-value, decimals: decimals))!, decimals: decimals) : floored(value, decimals: decimals)
    }

    /// Up to `maxDecimals` places with trailing zeros (and a trailing dot) removed: 3.000 -> "3".
    static func compact(_ value: Double, maxDecimals: Int = 3) -> String {
        var s = fixed(value, decimals: maxDecimals)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// "1h 02m 03s" style duration.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "unknown" }
        let total = Int(min(max(0, seconds), 1e9).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%dh %02dm %02ds", h, m, s) : String(format: "%dm %02ds", m, s)
    }
}
