import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Offscreen renders of the editing overlays (handles, nodes, pen, inspectors) to catch drawing
/// crashes. Set LOFTLINE_RENDER_DIR to keep the PNGs.
@Suite struct EditingRenderTests {
    let smoke = RenderSmokeTests()

    @MainActor func canvas(_ doc: LoftLineDocument) -> CanvasNSView {
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view.document = doc
        view.layout()
        return view
    }

    @Test @MainActor func selectionHandlesAndHandleDragRender() throws {
        let doc = smoke.sampleDocument()
        let view = canvas(doc)
        let box = doc.project.bounds(of: doc.selection)
        view.drag = .handle(.topRight, box: box, startDoc: box.max, currentDoc: box.max + Vec2(2, 1))
        let data = try #require(smoke.png(view))
        smoke.keep(data, "edit-handles.png")
        view.drag = .handle(.rotate, box: box, startDoc: box.center + Vec2(0, 5), currentDoc: box.center + Vec2(-5, 0))
        let rotated = try #require(smoke.png(view))
        smoke.keep(rotated, "edit-rotate.png")
        #expect(AppTestSupport.looksDrawn(data) && AppTestSupport.looksDrawn(rotated))
    }

    @Test @MainActor func nodeEditingRenders() throws {
        let doc = smoke.sampleDocument()
        let star = doc.document.shapes[3]
        doc.setSelection([doc.document.shapes[2].id, star.id])
        doc.activeTool = .nodeEdit
        doc.nodeSelection = [NodeRef(shapeID: star.id, path: 0, node: 0), NodeRef(shapeID: star.id, path: 0, node: 1)]
        let view = canvas(doc)
        let a = try #require(doc.project.nodePosition(NodeRef(shapeID: star.id, path: 0, node: 0)))
        view.drag = .nodes(anchor: a, startDoc: a, currentDoc: a + Vec2(1, 1))
        let data = try #require(smoke.png(view))
        smoke.keep(data, "edit-nodes.png")
        #expect(AppTestSupport.looksDrawn(data))
    }

    @Test @MainActor func penPreviewRenders() throws {
        let doc = smoke.sampleDocument()
        doc.activeTool = .pen
        let view = canvas(doc)
        view.pen.addNode(Vec2(2, 2))
        view.pen.addNode(Vec2(6, 4)); view.pen.dragLastHandle(to: Vec2(8, 6))
        view.hoverDoc = Vec2(10, 2)
        view.lastSnap = .init(point: Vec2(10, 2), kind: .node)
        let data = try #require(smoke.png(view))
        smoke.keep(data, "edit-pen.png")
        #expect(AppTestSupport.looksDrawn(data))
    }

    @Test @MainActor func inspectorsRender() throws {
        let doc = smoke.sampleDocument()
        for (tool, name) in [(CanvasTool.nodeEdit, "inspector-nodes.png"), (.rectangle, "inspector-rect.png"),
                             (.select, "inspector-shape.png")] {
            doc.activeTool = tool
            let host = NSHostingView(rootView: InspectorView(document: doc).environmentObject(doc.toolLibrary))
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 1100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            let data = try #require(smoke.png(host))
            smoke.keep(data, name)
            #expect(AppTestSupport.looksDrawn(data), Comment(rawValue: name))
        }
    }
}
