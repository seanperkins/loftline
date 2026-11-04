import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingMeasureTests {
    @Test func twoPoints() {
        let m = Measurement.between(Vec2(1, 1), Vec2(4, 5))
        #expect(m.distance == 5 && m.dx == 3 && m.dy == 4)
        #expect(abs(m.angle! - 53.130102354) < 1e-6)
        #expect(Measurement.between(.zero, Vec2(0, -1)).angle == 270)
        #expect(m.lines(units: .inch).contains("Distance 5 in"))
    }

    @Test func clickedArcGivesRadius() {
        let circle = Shape(layerID: UUID(), paths: [ShapeFactory.circle(center: Vec2(2, 2), radius: 1.5)])
        let m = Measurement.vector(circle, at: Vec2(3.5, 2), tolerance: 0.001)
        #expect(abs(m.radius! - 1.5) < 1e-9 && m.center == Vec2(2, 2))
        #expect(abs(m.length! - 3 * .pi) < 1e-3)
        let sq = Shape(layerID: UUID(), paths: [Path(points: [.zero, Vec2(2, 0), Vec2(2, 1), Vec2(0, 1)], closed: true)])
        let s = Measurement.vector(sq, at: Vec2(1, 0), tolerance: 0.001)
        #expect(s.radius == nil && s.length == 6 && s.bounds?.width == 2)
    }
}
