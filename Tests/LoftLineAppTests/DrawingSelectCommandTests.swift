import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingSelectCommandTests {
    func makeDoc() -> (LoftLineDocument, [UUID]) {
        var p = AppTestSupport.project()
        let layer = p.document.defaultLayerID
        p.document.add(AppTestSupport.rect(1, 1, 2, 1, layer: layer)) // copy of the first rectangle
        p.document.add(Shape(name: "L", layerID: layer, paths: [Path(points: [.zero, Vec2(3, 3)], closed: false)]))
        p.document.add(AppTestSupport.rect(10, 10, 2, 1, layer: layer)) // same size elsewhere
        p.document.add(AppTestSupport.rect(20, 10, 3, 1, layer: layer))
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        return (doc, p.document.shapes.map(\.id))
    }

    @Test func selectHelpers() {
        let (doc, ids) = makeDoc()
        #expect(doc.selectOpenVectors() && doc.selection == [ids[3]])
        #expect(doc.selectDuplicateVectors() && doc.selection == [ids[2]])
        doc.setSelection([ids[0]])
        #expect(doc.selectSimilarVectors())
        #expect(doc.selection == Set([ids[0], ids[1], ids[2], ids[4]]))
        #expect(doc.invertSelection() && doc.selection == Set([ids[3], ids[5]]))
        #expect(doc.selectShapes(onLayer: doc.project.document.defaultLayerID) && doc.selection.count == 6)
        // Nothing found: selection kept.
        doc.setSelection([ids[0]])
        doc.perform("Delete") { $0.deleteShapes([ids[3]]) }
        #expect(!doc.selectOpenVectors() && doc.selection == [ids[0]])
    }

    @Test func lockedLayersAreSkipped() {
        let (doc, ids) = makeDoc()
        let layer = doc.project.document.defaultLayerID
        doc.perform("Lock") { p in
            if let i = p.document.layers.firstIndex(where: { $0.id == layer }) { p.document.layers[i].isLocked = true }
        }
        #expect(!doc.invertSelection())
        #expect(!ids.isEmpty)
    }
}
