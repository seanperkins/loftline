import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOModelPositionTests {
    func form() throws -> ModelPlacementForm {
        // 0.5 in tall model (12.7 mm) in 0.75 in material.
        let stl = "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 50 0 0\nvertex 0 50 12.7\nendloop\nendfacet\nendsolid t\n"
        return try ImportService.placementForm(data: Data(stl.utf8), fileName: "m.stl", project: LoftLineProject(),
                                               library: .seeded)
    }

    @Test func gapsAndAnchors() throws {
        var f = try form()
        #expect(abs(f.zHeight - 0.5) < 1e-9)
        #expect(abs(f.gapAbove) < 1e-9 && abs(f.gapBelow - 0.25) < 1e-9)
        f.anchor(.bottom)
        #expect(abs(f.gapAbove - 0.25) < 1e-9 && abs(f.gapBelow) < 1e-9)
        f.anchor(.center)
        #expect(abs(f.gapAbove - 0.125) < 1e-9 && abs(f.gapBelow - 0.125) < 1e-9)
        f.gapBelow = 0.05
        #expect(abs(f.gapAbove - 0.2) < 1e-9)
        #expect(abs(f.placedModel.depth - 0.7) < 1e-9 && abs(f.placedModel.zTop - 0.2) < 1e-9)
        f.fillBetweenGaps(above: 0.1, below: 0.1)
        #expect(abs(f.zHeight - 0.55) < 1e-9 && abs(f.gapBelow - 0.1) < 1e-9)
        f.gapAbove = -1
        #expect(f.gapAbove == 0)
    }
}
