import Foundation
import Testing
@testable import CADCore

@Suite struct TextOutlinerTests {
    let outliner = TextOutliner()

    @Test func capitalHeightMatchesSize() throws {
        let h = try outliner.outlines(for: "H", fontName: testFont, size: 2, origin: Vec2(1, 1))
        let b = Rect2(points: h.flatMap { $0.flattened() })
        #expect(approx(b.height, 2, 0.02))
        #expect(approx(b.min.y, 1, 0.01)) // sits on the baseline
        #expect(b.min.x >= 1)
    }

    @Test func counterIsAHoleWithOppositeWinding() throws {
        let o = try outliner.outlines(for: "O", fontName: testFont, size: 1, origin: .zero)
        #expect(o.count == 2)
        #expect(o.allSatisfy { $0.isClosed })
        let areas = o.map { $0.signedArea() }.sorted()
        #expect(areas[0] < 0 && areas[1] > 0 && abs(areas[0]) < areas[1])
    }

    @Test func alignmentShiftsLines() throws {
        let left = Rect2(points: try outliner.outlines(for: "KERF", fontName: testFont, size: 1, origin: .zero).flatMap { $0.flattened() })
        let centre = Rect2(points: try outliner.outlines(for: "KERF", fontName: testFont, size: 1, origin: .zero,
                                                          alignment: .center).flatMap { $0.flattened() })
        let right = Rect2(points: try outliner.outlines(for: "KERF", fontName: testFont, size: 1, origin: .zero,
                                                         alignment: .right).flatMap { $0.flattened() })
        #expect(left.min.x >= -1e-9)
        #expect(abs(centre.center.x) < 0.1)
        #expect(right.max.x <= 1e-9)
        #expect(approx(left.width, right.width, 1e-9))
    }

    @Test func multipleLinesStackDownward() throws {
        let one = try outliner.outlines(for: "A", fontName: testFont, size: 1, origin: .zero)
        let two = try outliner.outlines(for: "A\nA", fontName: testFont, size: 1, origin: .zero)
        #expect(two.count == one.count * 2)
        #expect(Rect2(points: two.flatMap { $0.flattened() }).min.y < -1)
    }

    @Test func unknownFontThrows() {
        #expect(throws: TextOutliner.TextError.self) {
            try outliner.outlines(for: "A", fontName: "No Such Font LoftLine 123", size: 1, origin: .zero)
        }
    }

    @Test func fontListAndShapeProvenance() throws {
        let names = TextOutliner.availableFontNames()
        #expect(names.contains(testFont))
        #expect(!names.contains { $0.hasPrefix(".") })
        let s = try outliner.shape(for: "Hi", fontName: testFont, size: 0.5, origin: .zero, layerID: UUID())
        #expect(s.origin == .text("Hi", fontName: testFont, size: 0.5))
        #expect(s.isClosed && s.paths.count >= 3)
    }
}
