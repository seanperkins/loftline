import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewAppearanceTests {
    @Test func hexRoundTrip() {
        let c = StockColor(0.2, 0.4, 1)
        #expect(c.hex == "#3366FF")
        #expect(StockColor(hex: "#3366FF") == StockColor(51 / 255, 102 / 255, 1))
        #expect(StockColor(hex: "zz") == nil)
    }

    @Test func settingsRoundTripAndAppearance() {
        let name = "loftline-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(PreviewAppearanceSettings.load(from: d) == PreviewAppearanceSettings())
        var s = PreviewAppearanceSettings()
        s.material = .walnut; s.paintTop = true; s.paintColor = StockColor(hex: "#102030")!
        s.colorMachined = true; s.machinedColor = StockColor(hex: "#FFAA00")!
        s.save(to: d)
        #expect(PreviewAppearanceSettings.load(from: d) == s)
        let a = s.appearance
        #expect(a.paint == s.paintColor)
        #expect(a.machinedOverride == s.machinedColor)
        #expect(a.surface == StockAppearance.preset(.walnut).surface)
    }
}
