import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct IOMeshImportTests {
    static let tetra = "v 0 0 0\nv 50 0 0\nv 0 0 -50\nv 0 10 0\nf 1 3 2\nf 1 2 4\nf 2 3 4\nf 3 1 4\n"

    @Test func objOpensThePlacementForm() throws {
        #expect(ImportService.isMesh("part.OBJ"))
        let p = LoftLineProject()
        let form = try ImportService.placementForm(data: Data(Self.tetra.utf8), fileName: "part.obj", project: p,
                                                   library: .seeded)
        #expect(form.placedModel.mesh.triangleCount == 4)
        var q = LoftLineProject()
        let out = try ImportService.importFile(data: Data(Self.tetra.utf8), fileName: "part.obj", into: &q)
        #expect(out.modelIDs.count == 1)
        #expect(q.document.models[0].name == "part")
    }

    @Test func sketchUpFilesExplainTheExportRoute() {
        var p = LoftLineProject()
        #expect(ImportService.allExtensions.contains("skp") && ImportService.isMesh("model.dae"))
        do {
            _ = try ImportService.importFile(data: Data([0xFF, 0xFE]), fileName: "house.skp", into: &p)
            Issue.record("expected an error")
        } catch {
            #expect(ImportService.describe(error).contains("COLLADA"))
        }
    }
}
