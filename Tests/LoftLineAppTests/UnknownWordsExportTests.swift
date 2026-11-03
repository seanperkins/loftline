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
        // A code the validator does not model keeps its own warning, and only that one.
        var m98 = BuiltInPosts.massoG3Inch
        m98.id = "masso-g3-inch-custom-2"
        m98.preamble.append("M98")
        let r98 = GCodeExporter.export(project: project, toolpaths: tps, profile: m98, jobName: "T")
        #expect(r98.issues.contains { $0.message.hasPrefix("M98 is not a code this validator knows") })
        #expect(!r98.issues.contains { $0.message.contains("which the built-in") })
    }
}
