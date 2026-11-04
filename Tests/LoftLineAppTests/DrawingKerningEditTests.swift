import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct DrawingKerningEditTests {
    @Test func dragLettersIsUndoableAndKeepsTextLive() throws {
        var p = AppTestSupport.project()
        let spec = TextSpec(string: "ABC", fontName: "Helvetica", size: 1, anchor: Vec2(10, 5))
        let s = try TextOutliner().shape(for: spec, layerID: p.document.defaultLayerID)
        p.document.add(s)
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        // Needs exactly one text object.
        doc.clearSelection()
        doc.beginKerning()
        #expect(doc.kerningShapeID == nil && doc.alert != nil)
        doc.alert = nil
        doc.beginKerning(s.id)
        #expect(doc.kerningShape?.id == s.id && doc.selection == [s.id])

        let letters = try TextKerning.letters(for: spec)
        #expect(LoftLineDocument.kerningGroup(1, in: letters, restOfLine: true) == [1, 2])
        #expect(LoftLineDocument.kerningGroup(1, in: letters, restOfLine: false) == [1])

        let before = doc.project
        um.beginUndoGrouping(); doc.kernLetters([1, 2], by: Vec2(0.5, 0)); um.endUndoGrouping()
        let t = try #require(doc.project.document.shape(id: s.id)?.text)
        #expect(t.letterAdjustments?.map(\.index) == [1, 2])
        #expect(abs(doc.project.document.shape(id: s.id)!.bounds().max.x - s.bounds().max.x - 0.5) < 1e-6)
        um.undo()
        #expect(doc.project == before)
        um.redo()
        um.beginUndoGrouping(); doc.resetKerning(); um.endUndoGrouping()
        #expect(doc.project.document.shape(id: s.id)?.text?.letterAdjustments == nil)
        doc.endKerning()
        #expect(doc.kerningShape == nil)
    }
}
