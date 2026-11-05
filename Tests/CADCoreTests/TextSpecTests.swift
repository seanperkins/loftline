import Foundation
import Testing
@testable import CADCore

@Suite struct TextSpecTests {
    let outliner = TextOutliner()
    let layer = UUID()

    func box(_ paths: [Path]) -> Rect2 { Rect2(points: paths.flatMap { $0.flattened() }) }

    @Test func liveTextFollowsTransforms() throws {
        let spec = TextSpec(string: "KERF", fontName: testFont, size: 1, anchor: Vec2(2, 3))
        let s = try outliner.shape(for: spec, layerID: layer)
        #expect(s.text == spec)
        let t = Transform2D.rotation(.pi / 6, about: Vec2(1, 1)).concatenating(.scale(2, 2))
        let moved = s.transformed(t)
        // Re-outlining the moved spec reproduces the moved outlines.
        let rebuilt = try outliner.outlines(for: moved.text!)
        let a = box(moved.paths), b = box(rebuilt)
        #expect(a.min.isApproximatelyEqual(to: b.min, tolerance: 1e-6) && a.max.isApproximatelyEqual(to: b.max, tolerance: 1e-6))
        #expect(abs(moved.text!.displayedSize - 2) < 1e-9)
    }

    @Test func letterSpacingWidensAndAlignmentUsesVisibleWidth() throws {
        let plain = box(try outliner.outlines(for: "ABC", fontName: testFont, size: 1, origin: .zero, alignment: .left))
        let wide = box(try outliner.outlines(for: "ABC", fontName: testFont, size: 1, origin: .zero, alignment: .left,
                                             letterSpacing: 0.5))
        #expect(abs(wide.width - plain.width - 1) < 0.01)  // two gaps between three letters
        let right = box(try outliner.outlines(for: "ABC", fontName: testFont, size: 1, origin: .zero, alignment: .right,
                                              letterSpacing: 0.5))
        #expect(right.max.x <= 0.05 && right.max.x > -0.2)
    }

    @Test func olderFilesWithoutTextDecode() throws {
        let s = Shape(layerID: layer, paths: [])
        var json = String(data: try JSONEncoder().encode(s), encoding: .utf8)!
        #expect(!json.contains("\"text\""))
        json = json.replacingOccurrences(of: "\"groupID\":null,", with: "")
        let back = try JSONDecoder().decode(Shape.self, from: Data(json.utf8))
        #expect(back.text == nil)
        let live = try outliner.shape(for: TextSpec(string: "A", fontName: testFont, size: 1), layerID: layer)
        #expect(try JSONDecoder().decode(Shape.self, from: JSONEncoder().encode(live)) == live)
    }
}
