import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PhotoVCarveModelTests {
    @Test func newPhotoVCarveIsCentredOnTheMaterialWithAVBit() throws {
        let p = AppTestSupport.project()
        let op = try #require(OperationFactory.make(kind: .photoVCarve, project: p, library: .seeded,
                                                    shapeIDs: [p.document.shapes[0].id]))
        guard case .photoVCarve(let o) = op else { Issue.record("wrong kind"); return }
        #expect(o.setup.shapeIDs.isEmpty)
        #expect(ToolLibrary.seeded.tool(id: o.setup.toolID)?.kind == .vBit)
        let job = p.document.job
        #expect(abs(o.params.origin.x + o.params.width / 2 - job.width / 2) < 1e-9)
        #expect(o.params.width <= job.width * 0.8 + 1e-9 && o.params.height <= job.height * 0.8 + 1e-9)
        #expect(OperationFactory.menuKinds.contains(.photoVCarve))
    }

    @Test func photoVCarveLengthsScaleToMillimetres() throws {
        var p = AppTestSupport.project()
        p.operations = [try #require(OperationFactory.make(kind: .photoVCarve, project: p, library: .seeded, shapeIDs: []))]
        let mm = p.converted(to: .millimeter)
        guard case .photoVCarve(let a) = p.operations[0], case .photoVCarve(let b) = mm.operations[0] else {
            Issue.record("kind changed"); return
        }
        #expect(abs(b.params.lineSpacing - a.params.lineSpacing * 25.4) < 1e-9)
        #expect(abs(b.params.width - a.params.width * 25.4) < 1e-9)
        #expect(abs(b.params.origin.y - a.params.origin.y * 25.4) < 1e-9)
        #expect(b.params.angle == a.params.angle)
    }
}
