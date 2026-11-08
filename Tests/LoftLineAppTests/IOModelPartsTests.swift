import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct IOModelPartsTests {
    /// OBJ (millimetres) with two loose boxes: 254 x 508 x 19.05 and 127 x 203.2 x 12.7.
    static func twoBoards() -> Data {
        var s = ""
        var base = 0
        func box(_ lo: (Double, Double, Double), _ hi: (Double, Double, Double)) {
            for z in [lo.2, hi.2] { for (x, y) in [(lo.0, lo.1), (hi.0, lo.1), (hi.0, hi.1), (lo.0, hi.1)] { s += "v \(x) \(y) \(z)\n" } }
            for q in [[1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [2, 3, 7, 6], [3, 4, 8, 7], [4, 1, 5, 8]] {
                s += "f " + q.map { String($0 + base) }.joined(separator: " ") + "\n"
            }
            base += 8
        }
        box((0, 0, 0), (254, 508, 19.05))
        box((400, 0, 0), (527, 203.2, 12.7))
        return Data(s.utf8)
    }

    @Test func stlObjPartsAreConnectedPiecesLaidOutFlat() throws {
        var p = LoftLineProject()   // inch job
        let form = try ModelPartsForm.read(data: Self.twoBoards(), fileName: "shelf.obj", units: .inch)
        #expect(form.parts.count == 2)
        #expect(form.thicknessSummary(units: .inch).map(\.0) == ["0.5 in", "0.75 in"])
        let before = p.document.layers.count
        let out = form.apply(to: &p)
        #expect(out.shapeIDs.count == 2)
        #expect(p.document.layers.count == before + 2)
        #expect(p.document.layers.contains { $0.name == "Parts 0.75 in" })
        let a = try #require(p.document.shape(id: out.shapeIDs[0]))
        #expect(a.isClosed && a.name == "shelf 1 (0.75 in)")
        let dims = [a.bounds().width, a.bounds().height].sorted()
        #expect(abs(dims[0] - 10) < 1e-6 && abs(dims[1] - 20) < 1e-6)
        // Laid out inside the material, from the bottom-left corner plus the gap.
        let mb = p.document.job.materialBounds
        #expect(abs(a.bounds().min.x - (mb.min.x + 0.5)) < 1e-6)
    }

    @Test func assembledViewUsesOneLayer() throws {
        var p = LoftLineProject()
        var form = try ModelPartsForm.read(data: Self.twoBoards(), fileName: "shelf.obj", units: .inch)
        form.view = .top
        let out = form.apply(to: &p)
        #expect(out.shapeIDs.count == 2)
        #expect(p.document.layers.contains { $0.name == "shelf" })
        #expect(!p.document.layers.contains { $0.name.hasPrefix("Parts ") })
    }

    @Test func sketchUpFilesAreExplained() {
        #expect(throws: LoftLineIOError.self) {
            _ = try ModelPartsForm.read(data: Data([0]), fileName: "house.skp", units: .inch)
        }
    }
}
