import AppKit
import SwiftUI
import LoftLineKit

/// A colour for the contrast arithmetic (sRGB components 0...1).
struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
}

/// WCAG contrast ratio, the measure the HIG's Accessibility guidance refers to (4.5:1 for text up to 17 pt).
enum ContrastRatio {
    static func luminance(_ c: RGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    static func ratio(_ a: RGB, against b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// The three meanings status text can have.
enum StatusTone: CaseIterable {
    case warning, error, success

    /// The text colour on a light background. The system's orange, red and green are bright fill and
    /// icon colours: as small text on white they are only about 2–3.6:1. These are the same hues, darker,
    /// at 5:1 or better on white (and above 4.5:1 on the light window grey).
    var lightText: RGB {
        switch self {
        case .warning: return RGB(0.604, 0.357, 0.000)  // #9A5B00
        case .error: return RGB(0.843, 0.000, 0.082)    // #D70015
        case .success: return RGB(0.122, 0.478, 0.200)  // #1F7A33
        }
    }

    fileprivate var darkText: NSColor {
        switch self {
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .success: return .systemGreen
        }
    }

    /// Dark mode keeps the system colour (plenty of contrast on a dark background); light mode uses `lightText`.
    var nsColor: NSColor {
        let light = lightText
        let dark = darkText
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension Color {
    static let warningText = StatusTone.warning.color
    static let errorText = StatusTone.error.color
    static let successText = StatusTone.success.color
}
