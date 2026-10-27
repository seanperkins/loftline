import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// A program is never posted from a toolpath calculated before a later change.
@Suite @MainActor struct CalculateUntilFreshTests {
    /// Two profile toolpaths on two rectangles; both use the seeded 1/4" end mill.
    func makeDoc() -> (doc: LoftLineDocument, library: ToolLibraryModel, ids: [UUID], tool: Tool) {
        var d = Document(name: "Fresh", job: JobSetup(width: 20, height: 10, thickness: 0.75))
        let l = d.defaultLayerID
        d.add(AppTestSupport.rect(1, 1, 4, 3, layer: l))
        d.add(AppTestSupport.rect(8, 1, 4, 3, layer: l))
        var p = LoftLineProject(document: d)
        p.operations = d.shapes.map { OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [$0.id])! }
        let library = AppTestSupport.library()
        let doc = LoftLineDocument(project: p, toolLibrary: library)
        return (doc, library, doc.project.operations.map(\.id), ToolLibrary.seeded.tool(id: p.operations[0].setup.toolID)!)
    }

    @Test func changingACarriedToolDuringCalculationPostsTheNewTool() async throws {
        let (doc, library, ids, tool) = makeDoc()
        let fresh = Task { @MainActor in await doc.calculateUntilFresh(targets: ids) }
        await Task.yield()                    // the calculation has started on its background queue
        var edited = tool
        edited.diameter = 0.375
        library.update(edited)                // the Tool Database edit lands while it runs
        #expect(await fresh.value)
        for id in ids {
            #expect(!doc.isStale(id))
            #expect(doc.results[id]?.toolpaths.first?.tool.diameter == 0.375, "the program is made with the new tool")
        }
    }

    @Test func itGivesUpAfterFivePassesOfConstantChange() async {
        let (doc, _, ids, _) = makeDoc()
        var passes = 0
        let ok = await doc.calculateUntilFresh(targets: ids, afterPass: {
            passes += 1
            doc.perform("Change") { $0.document.name = "Changed \(passes)" }
        })
        #expect(!ok && passes == 5)
    }

    @Test func theRecheckCoversTargetsThatBecameStaleLater() async {
        let (doc, _, ids, _) = makeDoc()
        doc.calculateNow([ids[1]])            // the second toolpath is fresh when the export begins
        #expect(!doc.isStale(ids[1]) && doc.isStale(ids[0]))
        var changed = false
        let ok = await doc.calculateUntilFresh(targets: ids, afterPass: {
            guard !changed else { return }
            changed = true
            doc.perform("Change") { $0.document.name = "Edited during the pass" }   // makes both stale
        })
        #expect(ok)
        #expect(ids.allSatisfy { !doc.isStale($0) }, "also the one that was fresh at the start")
    }

    @Test func anAlreadyFreshTargetNeedsNoPass() async {
        let (doc, _, ids, _) = makeDoc()
        doc.calculateNow(ids)
        var passes = 0
        #expect(await doc.calculateUntilFresh(targets: ids, afterPass: { passes += 1 }))
        #expect(passes == 0)
    }

    @Test func aTargetDeletedMeanwhileDoesNotBlockTheRest() async {
        let (doc, _, ids, _) = makeDoc()
        doc.perform("Delete") { $0.deleteOperation(ids[0]) }
        #expect(await doc.calculateUntilFresh(targets: ids))
        #expect(!doc.isStale(ids[1]))
    }
}
