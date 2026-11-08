import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct LayoutFixtureCommandTests {
    @Test func clampsGoOnAKeepOutLayer() {
        var p = AppTestSupport.project()
        var o = ClampOptions.defaults(for: .inch)
        o.perSideEdge = 2
        o.perEndEdge = 1
        let ids = FixtureCommands.addClamps(o, in: &p)
        #expect(ids.count == 6)
        let layer = p.document.layers.first { $0.name == "Clamps" }
        #expect(layer?.keepOut?.height == o.height)
        #expect(Fixtures.zones(in: p.document).count == 6)
        // Adding more reuses the layer.
        _ = FixtureCommands.addClamps(o, in: &p)
        #expect(p.document.layers.filter { $0.name == "Clamps" }.count == 1)
        // Clamps hanging off the material are not "vectors outside the material".
        #expect(LayoutChecks.design(p.document).isEmpty)
    }

    @Test func holesForDrillingAreOrdinaryVectors() {
        var p = AppTestSupport.project()
        var o = HoleOptions.defaults(for: .inch)
        o.keepOut = false
        let ids = FixtureCommands.addHoles(o, in: &p)
        #expect(!ids.isEmpty)
        let layer = p.document.layer(id: p.document.shape(id: ids[0])!.layerID)
        #expect(layer?.name == "Fixture Holes")
        #expect(layer?.keepOut == nil)
        o.keepOut = true
        let screws = FixtureCommands.addHoles(o, in: &p)
        #expect(p.document.layer(id: p.document.shape(id: screws[0])!.layerID)?.keepOut != nil)
    }

    @Test func nestingKeepsPartsClearOfClamps() {
        var doc = Document(job: JobSetup(width: 20, height: 10))
        let part = AppTestSupport.rect(30, 0, 6, 6, layer: doc.defaultLayerID)
        doc.add(part)
        var p = LoftLineProject(document: doc)
        // A clamp zone over the left 8 inches.
        let layer = FixtureCommands.keepOutLayer(named: "Clamps", height: 1, in: &p)
        p.document.add(AppTestSupport.rect(-1, -1, 9, 12, layer: layer))
        var o = NestingOptions.defaults(for: .inch)
        o.precision = .draft
        o.avoidOtherVectors = false
        let r = NestingCommands.nest([part.id], options: o, in: &p)
        #expect(r.placed == 1)
        #expect(p.document.shape(id: part.id)!.bounds().min.x >= 8 + 0.375 - 1e-6)
    }

    @Test func toolpathsIntoClampsFailValidationAndClampsAreNeverCut() {
        var p = AppTestSupport.project()  // rectangles at (1,1) and (5,1), 2x1
        let layer = FixtureCommands.keepOutLayer(named: "Clamps", height: 1, in: &p)
        let clamp = AppTestSupport.rect(2.5, 0, 1, 3, layer: layer)
        p.document.add(clamp)
        p.operations = [
            OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!,
            OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [clamp.id])!,
        ]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(doc.project.operations.map(\.id))
        let ex = GCodeExporter.export(project: doc.project, toolpaths: doc.results[p.operations[0].id]!.toolpaths,
                                      profile: doc.postProfile, jobName: "t", expected: .notChecked(because: "test"))
        #expect(ex.issues.contains { $0.severity == .error && $0.message.contains("keep-out zone") })
        #expect(doc.results[p.operations[1].id]?.error?.contains("never machined") == true)
    }
}
