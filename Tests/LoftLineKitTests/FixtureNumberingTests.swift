import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

/// Clamps and Fixture Holes run again numbers on from what the layer already holds, so every clamp keeps a name of its own.
@Suite struct FixtureNumberingTests {
    func names(on layer: String, _ p: LoftLineProject) -> [String] {
        let id = p.document.layers.first { $0.name == layer }?.id
        return p.document.shapes.filter { $0.layerID == id }.map(\.name)
    }

    @Test func clampsAddedAgainNumberOn() {
        var p = AppTestSupport.project()
        var o = ClampOptions.defaults(for: .inch)
        o.perSideEdge = 1
        _ = FixtureCommands.addClamps(o, in: &p)
        _ = FixtureCommands.addClamps(o, in: &p)
        #expect(names(on: "Clamps", p) == ["Clamp 1", "Clamp 2", "Clamp 3", "Clamp 4"])
        #expect(ClampList.items(in: p.document).map(\.name) == ["Clamp 1", "Clamp 2", "Clamp 3", "Clamp 4"])
    }

    /// Review finding: a name with a huge number (typed, or in a file someone sent) must not crash the next Add Clamps.
    @Test func aHugeNumberInANameIsIgnoredInsteadOfOverflowing() throws {
        var p = AppTestSupport.project()
        var o = ClampOptions.defaults(for: .inch)
        o.perSideEdge = 1
        _ = FixtureCommands.addClamps(o, in: &p)
        let layer = try #require(p.document.layers.first { $0.name == "Clamps" }).id
        p.document.add(Shape(name: "Clamp \(Int.max)", layerID: layer, paths: [ShapeFactory.rectangle(Rect2(x: 2, y: 2, width: 1, height: 1))]))
        p.document.add(Shape(name: "Clamp \(Int.max - 1)", layerID: layer, paths: [ShapeFactory.rectangle(Rect2(x: 5, y: 2, width: 1, height: 1))]))
        _ = FixtureCommands.addClamps(o, in: &p)
        #expect(names(on: "Clamps", p).suffix(2) == ["Clamp 3", "Clamp 4"])
    }

    @Test func screwsAndHolesAddedAgainNumberOn() {
        var p = AppTestSupport.project()
        var o = HoleOptions.defaults(for: .inch)
        o.spacingX = 100
        o.spacingY = 100   // one hole on the 24 x 18 material
        _ = FixtureCommands.addHoles(o, in: &p)
        _ = FixtureCommands.addHoles(o, in: &p)
        #expect(names(on: "Screws", p) == ["Screw 1", "Screw 2"])
        o.keepOut = false
        _ = FixtureCommands.addHoles(o, in: &p)
        _ = FixtureCommands.addHoles(o, in: &p)
        #expect(names(on: "Fixture Holes", p) == ["Hole 1", "Hole 2"])
    }
}
