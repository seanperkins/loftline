import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct AccessibilityTests {
    @Test func describesKindSizePositionLayerAndState() {
        var doc = Document()
        let layer = doc.defaultLayerID
        var r = AppTestSupport.rect(1, 2, 3, 4, layer: layer)
        r.origin = .rectangle(width: 3, height: 4, cornerRadius: 0)
        r.name = "Rectangle"
        doc.add(r)
        let p = LoftLineProject(document: doc)
        let text = CanvasAccessibility.describe(r, in: p, selected: true)
        #expect(text.hasPrefix("Rectangle, 3 by 4 in, at X 1 Y 2, layer "))
        #expect(text.hasSuffix("selected"))
        #expect(!text.contains("Rectangle, Rectangle"))
        #expect(CanvasAccessibility.describe(r, in: p, selected: false).contains("selected") == false)

        var t = r
        t.origin = .text("HI", fontName: "Helvetica", size: 1)
        #expect(CanvasAccessibility.kind(t) == "Text \u{201C}HI\u{201D}")
    }

    @Test func summaryCountsVisibleShapesAndSelection() {
        let p = AppTestSupport.project()
        #expect(CanvasAccessibility.summary(p, selectionCount: 0).hasPrefix("2 vectors on material"))
        #expect(CanvasAccessibility.summary(p, selectionCount: 1).hasSuffix(", 1 selected"))
    }

    @Test func tabCyclesThroughShapesAndWraps() {
        let p = AppTestSupport.project()
        let ids = p.document.shapes.map(\.id)
        #expect(CanvasAccessibility.next(after: [], in: p, forward: true) == ids[0])
        #expect(CanvasAccessibility.next(after: [], in: p, forward: false) == ids[1])
        #expect(CanvasAccessibility.next(after: [ids[0]], in: p, forward: true) == ids[1])
        #expect(CanvasAccessibility.next(after: [ids[1]], in: p, forward: true) == ids[0])
        #expect(CanvasAccessibility.next(after: [ids[0]], in: p, forward: false) == ids[1])
    }

    @Test func tabSkipsLockedShapesAndStopsOncePerGroup() {
        var doc = Document()
        let l = doc.defaultLayerID
        let g = UUID()
        var a = AppTestSupport.rect(0, 0, 1, 1, layer: l); a.groupID = g
        var b = AppTestSupport.rect(2, 0, 1, 1, layer: l); b.groupID = g
        var c = AppTestSupport.rect(4, 0, 1, 1, layer: l); c.isLocked = true
        let d = AppTestSupport.rect(6, 0, 1, 1, layer: l)
        for s in [a, b, c, d] { doc.add(s) }
        let p = LoftLineProject(document: doc)
        #expect(CanvasAccessibility.tabStops(p) == [a.id, d.id])
        // Selecting the group (any member) moves on to d, then wraps to the group.
        #expect(CanvasAccessibility.next(after: [b.id], in: p, forward: true) == d.id)
        #expect(CanvasAccessibility.next(after: [d.id], in: p, forward: true) == a.id)
    }

    @Test func documentTabSelectionSelectsWholeGroup() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let ids = doc.document.shapes.map(\.id)
        doc.setSelection([ids[0], ids[1]])
        doc.groupSelection()
        doc.clearSelection()
        let next = CanvasAccessibility.next(after: [], in: doc.project, forward: true)
        #expect(next == ids[0])
        doc.select(next!, extending: false)
        #expect(doc.selection == Set(ids))
    }

    @Test func canvasViewExposesShapesToVoiceOver() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.document = doc
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityLabel() == "Design canvas")
        let children = try #require(view.accessibilityChildren() as? [CanvasShapeElement])
        #expect(children.count == 2)
        #expect(children[0].accessibilityLabel()?.contains("2 by 1 in") == true)
        // Pressing an element selects its shape.
        #expect(children[1].accessibilityPerformPress())
        #expect(doc.selection == [doc.document.shapes[1].id])
        #expect((view.accessibilitySelectedChildren() as? [CanvasShapeElement])?.map(\.shapeID) == [doc.document.shapes[1].id])
    }
}
