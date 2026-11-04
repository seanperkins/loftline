import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingEnvelopeEditTests {
    @Test func cornerHitAndDrag() throws {
        let p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        var e = try #require(EnvelopeEdit(ids, in: p))
        // Both rectangles: box (1,1)–(7,2).
        #expect(e.box.min == Vec2(1, 1) && e.box.max == Vec2(7, 2))
        #expect(e.corner(at: Vec2(7.05, 2), tolerance: 0.1) == 2)
        #expect(e.corner(at: Vec2(4, 1.5), tolerance: 0.1) == nil)
        e.move(2, to: Vec2(8, 3))
        #expect(e.offsets[2] == Vec2(1, 1))
        #expect(e.quad[2] == Vec2(8, 3))
        #expect(e.map(Vec2(7, 2)) == Vec2(8, 3))
        #expect(e.map(Vec2(1, 1)) == Vec2(1, 1))
    }

    @Test func applyIsOneUndoStep() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        let before = doc.project
        doc.setSelection(doc.project.document.shapes.map(\.id))
        doc.beginEnvelopeEdit()
        #expect(doc.envelopeEdit != nil)
        // Applying without moving anything changes nothing.
        doc.applyEnvelopeEdit()
        #expect(doc.envelopeEdit == nil && doc.project == before)
        doc.beginEnvelopeEdit()
        doc.envelopeEdit?.move(2, to: Vec2(9, 4))
        um.beginUndoGrouping(); doc.applyEnvelopeEdit(); um.endUndoGrouping()
        #expect(doc.project != before)
        #expect(doc.project.bounds(of: doc.selection).max.isApproximatelyEqual(to: Vec2(9, 4), tolerance: 1e-3))
        um.undo()
        #expect(doc.project == before)
        // Cancel leaves the design alone; nothing selected → no edit.
        doc.beginEnvelopeEdit(); doc.cancelEnvelopeEdit()
        #expect(doc.project == before)
        doc.clearSelection()
        doc.beginEnvelopeEdit()
        #expect(doc.envelopeEdit == nil && doc.alert != nil)
    }
}
