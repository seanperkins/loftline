import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct IOJobTemplateTests {
    @Test func saveListAndInstantiate() throws {
        let store = JobTemplateStore(directory: AppTestSupport.tempDir().appendingPathComponent("templates"))
        #expect(store.templates().isEmpty)
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.5
        p.document.job.zZero = .spoilboard
        p.operations = [OperationFactory.make(kind: .profile, project: p, library: .seeded,
                                              shapeIDs: p.document.shapes.map(\.id))!]
        p.postProfileID = "avid-mach4-mm"
        try store.save(p, name: "Signs: 1/2 in")
        try store.save(p, name: "Another")
        let list = store.templates()
        #expect(list.map(\.name) == ["Another", "Signs- 1-2 in"])
        let q = try store.instantiate(list[1])
        #expect(q.document.name == "Untitled")
        #expect(q.document.job == p.document.job)
        #expect(q.document.shapes == p.document.shapes)
        #expect(q.operations == p.operations)
        #expect(q.postProfileID == "avid-mach4-mm")
        // Saving under the same name replaces it.
        try store.save(LoftLineProject(), name: "Another")
        #expect(store.templates().count == 2)
        #expect(try store.instantiate(store.templates()[0]).operations.isEmpty)
    }
}
