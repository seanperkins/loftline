import Testing
@testable import CADCore

/// One rule for which Keep-Out Zones count, shared by the export check, lift-over, the footer check and the clamp list.
@Suite struct KeepOutZoneModelTests {
    @Test func anOutlineOfThreeOrMorePointsIsUsable() {
        #expect(!KeepOutZone(name: "Line", outline: [Vec2(0, 0), Vec2(1, 1)], height: 0).isUsable)
        #expect(!KeepOutZone(name: "Empty", outline: [], height: 0).isUsable)
        #expect(KeepOutZone(name: "Triangle", outline: [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1)], height: 0).isUsable)
    }
}
