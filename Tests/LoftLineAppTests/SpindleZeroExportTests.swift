import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The app says why a tool below 1 RPM cannot post (#99 item 10): before export in the tool warning, and in the export's error.
@Suite struct SpindleZeroExportTests {
    static let floor = "The spindle speed must be at least 1 RPM."

    @Test func theToolWarningNamesTheFloorWhateverThePost() {
        #expect(OperationWarnings.rpmProblem(0, profile: BuiltInPosts.avidMach4Inch) == Self.floor)
        #expect(OperationWarnings.rpmProblem(0.5, profile: BuiltInPosts.genericGRBLInch) == Self.floor)
        #expect(OperationWarnings.rpmProblem(.nan, profile: BuiltInPosts.genericGRBLInch) == Self.floor)
        #expect(OperationWarnings.rpmProblem(18000, profile: BuiltInPosts.avidMach4Inch) == nil)
        #expect(OperationWarnings.rpmProblem(1, profile: BuiltInPosts.genericGRBLInch) == nil)
    }

    @Test func exportingAZeroRPMToolSaysWhy() throws {
        let project = AppTestSupport.project()
        var library = ToolLibrary.seeded
        library.tools[0].spindleRPM = 0
        let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: library.tools[0].id,
                                                                             shapeIDs: project.document.shapes.map(\.id))))
        let tps = try op.generate(in: CAMContext(document: project.document, tools: library))
        let r = GCodeExporter.export(project: project, toolpaths: tps, profile: BuiltInPosts.genericGRBLInch, jobName: "T", expected: .notChecked(because: "test"))
        #expect(r.text == nil)
        #expect(r.errorMessage == "\(tps[0].name) has no spindle speed (below 1 RPM): set the tool's spindle speed.")
    }
}
