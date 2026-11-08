import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewMeasurementTests {
    @Test func distancesAndReadout() {
        var m = PreviewMeasurement()
        #expect(m.lines(units: .inch, thickness: 0.75).count == 1)
        m.add(Vec3(1, 1, 0))
        #expect(m.distance == nil)
        #expect(m.lines(units: .inch, thickness: 0.75)[0] == "A: X 1.000  Y 1.000  depth 0.000 in  (0.750 in left)")
        m.add(Vec3(4, 5, -0.25))
        #expect(abs(m.planarDistance! - 5) < 1e-12)
        #expect(abs(m.depthChange! - 0.25) < 1e-12)
        #expect(abs(m.distance! - (25 + 0.0625).squareRoot()) < 1e-12)
        let lines = m.lines(units: .inch, thickness: 0.75)
        #expect(lines.count == 3)
        #expect(lines[2].hasPrefix("Distance 5.006 in"))
        // A third pick starts over.
        m.add(Vec3(2, 2, 0))
        #expect(m.points.count == 1)
    }

    @Test func refinesDepthFromHeightfield() {
        var hf = Heightfield(width: 2, height: 2, cellSize: 0.1)
        let c = hf.cell(containing: Vec2(1.05, 1.05))!
        hf[c.i, c.j] = 0.3
        let p = PreviewMeasurement.refined(Vec3(1.05, 1.05, -0.1), heightfield: hf)
        #expect(abs(p.z + 0.3) < 1e-6)
        // Outside the stock the pick is kept as is.
        #expect(PreviewMeasurement.refined(Vec3(5, 5, -0.1), heightfield: hf) == Vec3(5, 5, -0.1))
    }
}
