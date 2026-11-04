import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DXFImportReportTests {
    /// File > Import builds its alert from `ImportOutcome.warnings`, so the gap note reaches the user,
    /// in the document's units.
    @Test func gapNoteReachesTheImportOutcomeInTheDocumentUnits() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CADCore/outline-with-gap.dxf")
        var project = LoftLineProject(document: Document(), postProfileID: BuiltInPosts.avidMach4Inch.id)
        #expect(project.document.units == .inch)
        let outcome = try ImportService.importFile(data: try Data(contentsOf: url), fileName: "outline-with-gap.dxf",
                                                   into: &project)
        #expect(outcome.shapeIDs.count == 1)
        let note = try #require(outcome.warnings.first { $0.contains("nearly meet") })
        #expect(note.contains("Layer \"Cabinet\""))
        #expect(note.contains("0.0079 in apart"))
    }
}
