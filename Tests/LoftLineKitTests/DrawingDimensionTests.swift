import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct DrawingDimensionTests {
    @Test func linearDimensions() throws {
        let d = try #require(DimensionBuilder.make(.aligned, clicks: [Vec2(0, 0), Vec2(3, 4), Vec2(-4, 3)]))
        #expect(d.value == 5 && abs(d.offset - 5) < 1e-9)
        let h = try #require(DimensionBuilder.make(.horizontal, clicks: [Vec2(1, 1), Vec2(4, 3), Vec2(2, 5)]))
        #expect(h.value == 3 && h.dimensionLine!.0 == Vec2(1, 5) && h.dimensionLine!.1 == Vec2(4, 5))
        #expect(DimensionBuilder.label(h, units: .inch) == "3 in")
        let v = try #require(DimensionBuilder.make(.vertical, clicks: [Vec2(1, 1), Vec2(4, 3), Vec2(6, 0)]))
        #expect(v.value == 2 && v.dimensionLine!.0.x == 6)
    }

    @Test func angleAndRadial() throws {
        let a = try #require(DimensionBuilder.make(.angle, clicks: [Vec2(0, 0), Vec2(2, 0), Vec2(0, 3)]))
        #expect(abs(a.value - 90) < 1e-9 && abs(a.offset - 1.2) < 1e-9)
        #expect(DimensionBuilder.label(a, units: .inch) == "90°")
        let r = try #require(DimensionBuilder.radial(.diameter, center: Vec2(1, 1), radius: 2, toward: Vec2(5, 1)))
        #expect(r.value == 4 && r.points[1] == Vec2(3, 1))
        #expect(DimensionBuilder.label(r, units: .millimeter) == "Ø 4")
    }

    @Test func dimensionsAreSavedAndScaledButNeverCut() throws {
        var doc = Document()
        doc.dimensions = [DimensionAnnotation(kind: .aligned, points: [.zero, Vec2(1, 0)], offset: 0.5)]
        let mm = doc.converted(to: .millimeter)
        #expect(abs(mm.dimensions![0].value - 25.4) < 1e-9 && abs(mm.dimensions![0].offset - 12.7) < 1e-9)
        let back = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(doc))
        #expect(back.dimensions == doc.dimensions)
        #expect(doc.shapes.isEmpty)  // annotations are not shapes, so no toolpath can select them
    }
}
