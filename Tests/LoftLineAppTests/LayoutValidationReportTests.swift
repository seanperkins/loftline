import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct LayoutValidationReportTests {
    @Test func vectorsOutsideTheMaterialGetTheirOwnSection() {
        var p = AppTestSupport.project()
        p.document.add(AppTestSupport.rect(30, 1, 2, 1, layer: p.document.defaultLayerID))
        p.operations = [OperationFactory.make(kind: .profile, project: p, library: .seeded,
                                              shapeIDs: [p.document.shapes[2].id])!]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        let report = ValidationReport.make(project: doc.project, results: doc.results, profile: doc.postProfile,
                                           groupByTool: false)
        #expect(report.sections.first?.title == "Material and machine")
        #expect(report.sections.first?.issues.first?.message.contains("outside the material") == true)
        // The profile around the stray vector cuts off the stock.
        #expect(report.sections[1].issues.contains { $0.message.contains("cuts outside the material") })
        #expect(doc.makeJobSheet(settings: TimeEstimateSettings()).warnings.contains { $0.contains("outside the material") })
    }
}
