import AppKit
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// HIG, Accessibility: text needs a 4.5:1 contrast ratio up to 17 pt. The system's orange, red and green
/// are bright colours meant for fills and icons, and fail it as small text on a light background.
@Suite struct StatusColorsTests {
    static let white = RGB(1, 1, 1)

    @Test func contrastRatioMatchesTheWCAGDefinition() {
        #expect(abs(ContrastRatio.ratio(RGB(0, 0, 0), against: Self.white) - 21) < 1e-9)
        #expect(abs(ContrastRatio.ratio(Self.white, against: Self.white) - 1) < 1e-9)
        // #767676 on white is the textbook 4.54:1.
        #expect(abs(ContrastRatio.ratio(RGB(118.0 / 255, 118.0 / 255, 118.0 / 255), against: Self.white) - 4.54) < 0.01)
    }

    @Test func theSystemColoursFailAsSmallTextOnWhite() {
        // Why the palette exists: system orange / green are about 2:1 on a light background.
        #expect(ContrastRatio.ratio(RGB(1.0, 0.584, 0.0), against: Self.white) < 3)   // systemOrange
        #expect(ContrastRatio.ratio(RGB(0.204, 0.78, 0.349), against: Self.white) < 3)  // systemGreen
    }

    @Test func lightModeStatusTextMeetsTheMinimumOnWhite() {
        for tone in StatusTone.allCases {
            let ratio = ContrastRatio.ratio(tone.lightText, against: Self.white)
            #expect(ratio >= 4.5, "\(tone) text is \(ratio):1 on white")
        }
    }

    @Test func lightModeStatusTextMeetsTheMinimumOnTheWindowBackground() {
        // The light window background is not pure white; #ECECEC is the darker end of it.
        let bg = RGB(236.0 / 255, 236.0 / 255, 236.0 / 255)
        for tone in StatusTone.allCases {
            #expect(ContrastRatio.ratio(tone.lightText, against: bg) >= 4.5, "\(tone) on the grey background")
        }
    }

    @Test func eachToneStillReadsAsItsColour() {
        // Darker, not a different hue: the dominant channel stays the one people expect.
        #expect(StatusTone.warning.lightText.r > StatusTone.warning.lightText.b)
        #expect(StatusTone.error.lightText.r > StatusTone.error.lightText.g)
        #expect(StatusTone.success.lightText.g > StatusTone.success.lightText.r)
    }
}

@Suite struct StatusColorResolutionTests {
    private func resolved(_ tone: StatusTone, _ name: NSAppearance.Name) -> RGB {
        var out = RGB(0, 0, 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = tone.nsColor.usingColorSpace(.sRGB)!
            out = RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return out
    }

    @Test func lightAppearanceResolvesToTheDarkerTextColour() {
        for tone in StatusTone.allCases {
            let c = resolved(tone, .aqua)
            let l = tone.lightText
            #expect(abs(c.r - l.r) < 0.01 && abs(c.g - l.g) < 0.01 && abs(c.b - l.b) < 0.01, "\(tone): \(c)")
            #expect(ContrastRatio.ratio(c, against: RGB(1, 1, 1)) >= 4.5)
        }
    }

    @Test func darkAppearanceKeepsTheBrighterSystemColour() {
        for tone in StatusTone.allCases {
            let c = resolved(tone, .darkAqua)
            // Brighter than the light-mode text colour, and well above 4.5:1 on a dark background.
            #expect(ContrastRatio.luminance(c) > ContrastRatio.luminance(tone.lightText))
            #expect(ContrastRatio.ratio(c, against: RGB(0.118, 0.118, 0.118)) >= 4.5, "\(tone) on dark")
        }
    }
}
