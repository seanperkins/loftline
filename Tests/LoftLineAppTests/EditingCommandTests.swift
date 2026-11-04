import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp

@Suite struct ShapeClipboardTests {
    @Test func copiesGetFreshIDsAndRemappedGroups() {
        let l = UUID(), g = UUID()
        let a = Shape(layerID: l, paths: [], groupID: g), b = Shape(layerID: l, paths: [], groupID: g)
        let c = Shape(layerID: UUID(), paths: [])
        let fallback = UUID()
        let out = ShapeClipboard.copies(of: [a, b, c], offset: .zero, layers: [l], fallbackLayer: fallback)
        #expect(Set(out.map(\.id)).isDisjoint(with: [a.id, b.id, c.id]))
        #expect(out[0].groupID != nil && out[0].groupID == out[1].groupID && out[0].groupID != g)
        #expect(out[2].layerID == fallback)
        #expect(out[2].groupID == nil)
    }

    @Test func copiesRemapNestedGroups() {
        let l = UUID(), outer = UUID(), inner = UUID()
        var a = Shape(layerID: l, paths: [], groupID: outer)
        a.innerGroupIDs = [inner]
        let out = ShapeClipboard.copies(of: [a], offset: .zero, layers: [l], fallbackLayer: l)
        #expect(out[0].groupID != outer && out[0].innerGroupIDs?.count == 1 && out[0].innerGroupIDs?[0] != inner)
    }

    @Test func pasteOffsetsOnlyWhenOriginalsExist() {
        let s = Shape(layerID: UUID(), paths: [])
        #expect(ShapeClipboard.pasteOffset(for: [s], existing: [s.id], grid: 0.25) == Vec2(0.25, -0.25))
        #expect(ShapeClipboard.pasteOffset(for: [s], existing: [], grid: 0.25) == .zero)
    }

    @Test func roundTripsThroughData() {
        let s = AppTestSupport.rect(0, 0, 1, 1, layer: UUID())
        #expect(ShapeClipboard.decode(ShapeClipboard.encode([s])!) == [s])
    }
}

@Suite struct ExactShapeTests {
    let layer = UUID()

    @Test func rectangleCentredWithExactSize() {
        let s = DrawingTools.exactShape(for: .rectangle, center: Vec2(5, 5), width: 4, height: 2,
                                        options: DrawingOptions(), layerID: layer)!
        let b = s.bounds()
        #expect(b.min == Vec2(3, 4) && b.max == Vec2(7, 6))
    }

    @Test func circleUsesWidthAsDiameter() {
        let s = DrawingTools.exactShape(for: .circle, center: Vec2(1, 1), width: 3, height: 99,
                                        options: DrawingOptions(), layerID: layer)!
        #expect(s.origin == .circle(radius: 1.5))
    }

    @Test func polygonHasVertexOnTop() {
        let s = DrawingTools.exactShape(for: .polygon, center: .zero, width: 2, height: 0,
                                        options: DrawingOptions(), layerID: layer)!
        #expect(abs(s.bounds().max.y - 1) < 1e-9)
    }

    @Test func invalidSizesMakeNothing() {
        #expect(DrawingTools.exactShape(for: .ellipse, center: .zero, width: 2, height: 0, options: DrawingOptions(), layerID: layer) == nil)
        #expect(DrawingTools.exactShape(for: .text, center: .zero, width: 2, height: 2, options: DrawingOptions(), layerID: layer) == nil)
    }

    @Test func toolShortcuts() {
        #expect(CanvasTool.forShortcut("n") == .nodeEdit)
        #expect(CanvasTool.forShortcut("p") == .pen)
        #expect(CanvasTool.forShortcut("z") == nil)
        #expect(CanvasTool.pen.isClickBuilt && !CanvasTool.rectangle.isClickBuilt)
    }
}

@Suite struct ProjectNodeEditingTests {
    @Test func moveDeleteAndConvertNodes() {
        var p = AppTestSupport.project()
        let s = p.document.shapes[0] // 2x1 rect at (1,1)
        let r = NodeRef(shapeID: s.id, path: 0, node: 2)
        #expect(p.nodePosition(r) == Vec2(3, 2))
        p.moveNodes([r], by: Vec2(1, 1))
        #expect(p.nodePosition(r) == Vec2(4, 3))
        p.convertSegments(after: [r], toCurve: true)
        #expect(PathNodes.handle(p.document.shapes[0].paths[0], 2, .outgoing) != nil)
        p.deleteNodes([r])
        #expect(PathNodes.anchorCount(p.document.shapes[0].paths[0]) == 3)
        #expect(p.validNodes([r]) == [r]) // triangle still has nodes 0…2
        #expect(p.validNodes([NodeRef(shapeID: s.id, path: 0, node: 3)]).isEmpty)
    }

    @Test func insertAfterReturnsNewRefs() {
        var p = AppTestSupport.project()
        let s = p.document.shapes[0]
        let new = p.insertNodesAfter([NodeRef(shapeID: s.id, path: 0, node: 0), NodeRef(shapeID: s.id, path: 0, node: 2)])
        #expect(PathNodes.anchorCount(p.document.shapes[0].paths[0]) == 6)
        #expect(new == [NodeRef(shapeID: s.id, path: 0, node: 1), NodeRef(shapeID: s.id, path: 0, node: 3)])
        #expect(p.nodePosition(NodeRef(shapeID: s.id, path: 0, node: 1)) == Vec2(2, 1))
    }

    @Test func lockedShapesAndLayersAreNotEdited() {
        var p = AppTestSupport.project()
        p.document.shapes[0].isLocked = true
        let before = p.document.shapes[0]
        p.moveNodes([NodeRef(shapeID: before.id, path: 0, node: 0)], by: Vec2(1, 1))
        #expect(p.document.shapes[0] == before)
        p.document.layers[0].isLocked = true
        let other = p.document.shapes[1]
        p.deleteNodes([NodeRef(shapeID: other.id, path: 0, node: 0)])
        #expect(p.document.shapes[1] == other)
    }

    @Test func layersReorder() {
        var p = AppTestSupport.project()
        let second = p.addLayer(named: "Two")
        p.moveLayer(second, by: -1)
        #expect(p.document.layers[0].id == second)
        p.moveLayer(second, by: -1)
        #expect(p.document.layers[0].id == second)
    }

    @Test func groupCommandsSkipLockedShapes() {
        var p = AppTestSupport.project()
        p.document.shapes[1].isLocked = true
        let ids = p.document.shapes.map(\.id)
        #expect(DesignCommands.group(ids, in: &p) == nil)
        p.document.shapes[1].isLocked = false
        #expect(DesignCommands.group(ids, in: &p) != nil)
        DesignCommands.ungroup([ids[0]], in: &p)
        #expect(p.document.shapes.allSatisfy { $0.groupID == nil })
    }

    @Test func equalSpacingDistribution() {
        var p = AppTestSupport.project()
        p.document.add(AppTestSupport.rect(4, 1, 1, 1, layer: p.document.defaultLayerID)) // between the two 2-wide rects
        DesignCommands.distributeSpacing(Set(p.document.shapes.map(\.id)), horizontally: true, in: &p)
        let xs = p.document.shapes.map { $0.bounds() }.sorted { $0.min.x < $1.min.x }
        let gap1 = xs[1].min.x - xs[0].max.x, gap2 = xs[2].min.x - xs[1].max.x
        #expect(abs(gap1 - gap2) < 1e-9)
    }
}

@Suite struct DocumentEditingTests {
    func makeDoc() -> (LoftLineDocument, UndoManager) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let um = UndoManager()
        um.groupsByEvent = false
        doc.undoManager = um
        return (doc, um)
    }

    func step(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    @Test func clickingAGroupMemberSelectsTheGroup() {
        let (doc, um) = makeDoc()
        let ids = doc.document.shapes.map(\.id)
        doc.setSelection(ids)
        step(um) { doc.groupSelection() }
        doc.clearSelection()
        doc.select(ids[1], extending: false)
        #expect(doc.selection == Set(ids))
        doc.select(ids[0], extending: true) // toggles the whole group off
        #expect(doc.selection.isEmpty)
        um.undo()
        #expect(doc.document.shapes.allSatisfy { $0.groupID == nil })
    }

    @Test func nodeEditsAreUndoable() {
        let (doc, um) = makeDoc()
        let original = doc.project
        let s = doc.document.shapes[0]
        doc.setSelection([s.id])
        doc.activeTool = .nodeEdit
        doc.nodeSelection = [NodeRef(shapeID: s.id, path: 0, node: 1)]
        step(um) { doc.moveSelectedNodes(by: Vec2(0, -1)) }
        #expect(um.undoActionName == "Move Nodes")
        step(um) { doc.deleteSelectedNodes() }
        #expect(doc.nodeSelection.isEmpty)
        um.undo(); um.undo()
        #expect(doc.project == original)
        um.redo()
        #expect(doc.project.nodePosition(NodeRef(shapeID: s.id, path: 0, node: 1)) == Vec2(3, 0))
    }

    @Test func nodesOfAShapeThatLeavesTheSelectionAreDropped() {
        // Duplicate (or Tab, or a sheet switch) changes the selection: arrow keys and Delete must not then edit nodes of
        // a shape that is no longer selected.
        let (doc, _) = makeDoc()
        let s = doc.document.shapes[0]
        doc.setSelection([s.id])
        doc.activeTool = .nodeEdit
        doc.nodeSelection = [NodeRef(shapeID: s.id, path: 0, node: 1)]
        doc.duplicateSelection()
        #expect(!doc.selection.contains(s.id))
        #expect(doc.nodeSelection.isEmpty)
        // Adding to the selection keeps the nodes of shapes still in it.
        doc.setSelection([s.id])
        doc.nodeSelection = [NodeRef(shapeID: s.id, path: 0, node: 1)]
        doc.setSelection([s.id, doc.document.shapes[1].id])
        #expect(doc.nodeSelection == [NodeRef(shapeID: s.id, path: 0, node: 1)])
        // A sheet or side switch clears the selection, and the nodes with it.
        doc.clearSelection()
        #expect(doc.nodeSelection.isEmpty)
    }

    @Test func theCanvasRunsOneSessionAtATime() {
        // Tab editing, an envelope and kerning each take the canvas's clicks; two at once stacked their banners and left
        // tab editing unresponsive.
        let (doc, _) = makeDoc()
        let opID = UUID()
        doc.setSelection(doc.document.shapes.map(\.id))
        doc.beginEnvelopeEdit()
        #expect(doc.envelopeEdit != nil)
        doc.tabEditingOperationID = opID
        #expect(doc.envelopeEdit == nil)
        doc.beginEnvelopeEdit()
        #expect(doc.tabEditingOperationID == nil && doc.envelopeEdit != nil)
        // Another tool ends the envelope rather than leave it taking clicks.
        doc.activeTool = .rectangle
        #expect(doc.envelopeEdit == nil)
    }

    @Test func deletingTheEnvelopesShapesEndsIt() {
        let (doc, _) = makeDoc()
        doc.setSelection([doc.document.shapes[0].id])
        doc.beginEnvelopeEdit()
        #expect(doc.envelopeEdit != nil)
        doc.deleteSelection()
        #expect(doc.envelopeEdit == nil)
    }

    @Test func leavingNodeToolClearsNodeSelection() {
        let (doc, _) = makeDoc()
        let s = doc.document.shapes[0]
        doc.activeTool = .nodeEdit
        doc.nodeSelection = [NodeRef(shapeID: s.id, path: 0, node: 0)]
        doc.activeTool = .select
        #expect(doc.nodeSelection.isEmpty)
    }

    @Test func pasteAndDuplicateAreUndoable() {
        let (doc, um) = makeDoc()
        let shapes = doc.document.shapes
        step(um) { doc.pasteShapes(shapes) }
        #expect(doc.document.shapes.count == 4)
        #expect(doc.selection.count == 2 && doc.selection.isDisjoint(with: shapes.map(\.id)))
        let pasted = doc.selectedShapes
        #expect(abs(pasted[0].bounds().min.x - (shapes[0].bounds().min.x + doc.document.gridSpacing)) < 1e-9)
        step(um) { doc.duplicateSelection() }
        #expect(doc.document.shapes.count == 6)
        um.undo(); um.undo()
        #expect(doc.document.shapes.count == 2)
    }

    @Test func transformSelectionIsOneUndoStep() {
        let (doc, um) = makeDoc()
        let original = doc.project
        doc.setSelection(doc.document.shapes.map(\.id))
        let t = TransformHandles.transform(dragging: .topRight, box: doc.project.bounds(of: doc.selection),
                                           from: Vec2(7, 2), to: Vec2(13, 3), keepAspect: false, fromCenter: false)
        step(um) { doc.transformSelection(by: t, actionName: "Scale") }
        let b = doc.project.bounds(of: doc.selection)
        #expect(abs(b.max.x - 13) < 1e-9 && abs(b.max.y - 3) < 1e-9 && abs(b.min.x - 1) < 1e-9)
        um.undo()
        #expect(doc.project == original)
    }

    @Test func deletingAGroupMateDissolvesSingletonGroup() {
        let (doc, um) = makeDoc()
        let ids = doc.document.shapes.map(\.id)
        doc.setSelection(ids)
        step(um) { doc.groupSelection() }
        step(um) { doc.perform("Delete") { $0.deleteShapes([ids[1]]) } }
        #expect(doc.document.shape(id: ids[0])?.groupID == nil)
    }
}
