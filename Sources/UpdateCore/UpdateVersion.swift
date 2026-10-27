import Foundation

public enum UpdateVersion {
    /// 1 when `a` is newer than `b`, -1 when older, 0 when they are the same version. Dot-separated numeric parts, compared
    /// as numbers (0.4.10 is newer than 0.4.9); missing parts count as 0.
    public static func compare(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : "0"
            let y = i < pb.count ? pb[i] : "0"
            if x.count != y.count { return x.count > y.count ? 1 : -1 }
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    public static func isNewer(_ available: String, than current: String) -> Bool {
        compare(available, current) > 0
    }

    /// A leading "v" and everything from the first "-" or "+" on (a prerelease or build suffix, which may itself hold
    /// dots) are dropped. Each dot-separated part keeps its leading run of ASCII digits, without leading zeros; a part with
    /// no digits is "0". Parts stay strings so that a very long number compares without overflowing.
    private static func parts(_ version: String) -> [String] {
        var text = Substring(version)
        if text.first == "v" { text = text.dropFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { text = text[..<cut] }
        return text.split(separator: ".", omittingEmptySubsequences: false).map { part in
            let digits = part.prefix { $0.isASCII && $0.isNumber }.drop { $0 == "0" }
            return digits.isEmpty ? "0" : String(digits)
        }
    }
}
