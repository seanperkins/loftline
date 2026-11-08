import CADCore
import Foundation

/// Wording for depths and heights shown next to the cutting numbers.
public enum DepthText {
    /// A length to three decimals with trailing zeros dropped ("0.125", "-0.77", "19.05").
    public static func number(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        if r == 0 { return "0" }
        var s = String(format: "%.3f", r)   // not "%g": it keeps six significant digits and drops decimals from 1000 up
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
