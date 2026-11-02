import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Export warns of a word a copy writes that its built-in does not (#99 item 14).
@Suite struct UnknownWordsExportTests {
    @Test func exportCarriesTheWarning() throws {
        let project = AppTestSupport.project()
        let op = AnyOperation.profile(ProfileOperation(setup: OperationSetup(name: "Cut", toolID: ToolLibrary.seeded.tools[0].id,
                                                                             shapeIDs: project.document.shapes.map(\.id))))
        let tps = try op.generate(in: CAMContext(document: project.document, tools: .seeded))
        var copy = BuiltInPosts.massoG3Inch
        copy.id = "masso-g3-inch-custom-1"
        copy.preamble.append("G64 P0.01")
        let r = GCodeExporter.export(project: project, toolpaths: tps, profile: copy, jobName: "T")
        #expect(r.text != nil)
        #expect(r.issues.contains { $0.severity == .warning && $0.message.contains("writes G64, which the built-in MASSO G3") })
        let builtIn = GCodeExporter.export(project: project, toolpaths: tps, profile: BuiltInPosts.massoG3Inch, jobName: "T")
        #expect(!builtIn.issues.contains { $0.message.contains("which the built-in") })
    }
}
