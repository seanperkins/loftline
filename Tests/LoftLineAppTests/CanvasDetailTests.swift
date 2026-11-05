import AppKit
import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// A drawing of tens of thousands of curve segments (a traced image, an imported SVG) must draw in a fraction of a
/// second, not tens of seconds (issue #30): CoreGraphics' full stroker costs about 30 microseconds a segment.
@Suite struct CanvasDetailTests {
    /// A closed shape of `segments` cubic curves around (`x`, `y`).
    static func blob(x: Double, y: Double, segments: Int, layer: UUID) -> Shape {
        var path = Path(start: Vec2(x + 0.3, y))
        for k in 1...segments {
            let a0 = Double(k - 1) / Double(segments) * 2 * .pi, a1 = Double(k) / Double(segments) * 2 * .pi
            // Traced artwork wobbles: the control points sit at varying distances, so each curve really is a curve.
            let r = 0.3, wobble = 0.8 + 0.4 * Double((k * 7919 + Int(x * 100)) % 17) / 17
            path.segments.append(.cubic(to: Vec2(x + r * cos(a1), y + r * sin(a1)),
                                        control1: Vec2(x + r * wobble * cos(a0 + 0.1), y + r * wobble * sin(a0 + 0.1)),
                                        control2: Vec2(x + r * wobble * cos(a1 - 0.1), y + r * wobble * sin(a1 - 0.1))))
        }
        path.isClosed = true
        return Shape(layerID: layer, paths: [path])
    }

    /// `count` blobs in a grid inside the default 24 x 18 material, starting at column `firstColumn`.
    static func document(blobs count: Int, segments: Int, xOffset: Double = 1, yOffset: Double = 1) -> Document {
        var doc = Document()
        for i in 0..<count {
            doc.add(blob(x: xOffset + Double(i % 40) * 0.5, y: yOffset + Double(i / 40) * 0.5, segments: segments,
                         layer: doc.defaultLayerID))
        }
        return doc
    }

    /// The document the canvas draws (it holds it weakly: keep it alive while the canvas is used) and a canvas on it.
    @MainActor static func canvas(_ doc: Document, selectAll: Bool, viewport: CanvasViewport? = nil) -> (LoftLineDocument, CanvasNSView) {
        let kd = LoftLineDocument(project: LoftLineProject(document: doc), toolLibrary: AppTestSupport.library())
        if selectAll { kd.setSelection(doc.shapes.map(\.id)) }
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        view.document = kd
        view.layout()
        if let viewport { view.viewport = viewport }   // also keeps the canvas from fitting the drawing again
        return (kd, view)
    }

    /// A render of `doc`.
    @MainActor static func render(_ doc: Document, selectAll: Bool, viewport: CanvasViewport? = nil) throws -> Data {
        let (kd, view) = canvas(doc, selectAll: selectAll, viewport: viewport)
        defer { withExtendedLifetime(kd) {} }
        return try #require(AppTestSupport.png(of: view))
    }

    @Test func hairlinesAreForDrawingsTooBigForTheFullStroker() {
        #expect(!CanvasDetail.usesHairlines(segmentCount: 0))
        #expect(!CanvasDetail.usesHairlines(segmentCount: CanvasDetail.hairlineSegmentCount))
        #expect(CanvasDetail.usesHairlines(segmentCount: CanvasDetail.hairlineSegmentCount + 1))
        let doc = Self.document(blobs: 3, segments: 10)
        #expect(CanvasDetail.segmentCount(of: doc.shapes) == 3 * 10)
        // The sample sign (a few hundred segments) keeps the full look.
        let sign = RenderSmokeTests().sampleDocument().project.document
        #expect(!CanvasDetail.usesHairlines(segmentCount: CanvasDetail.segmentCount(of: sign.shapes)))
    }

    @Test func aShapeIsVisibleWhenItsStrokeCanReachTheView() {
        let view = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CanvasDetail.isVisible(CGRect(x: 10, y: 10, width: 5, height: 5), in: view))
        #expect(CanvasDetail.isVisible(CGRect(x: 99, y: 99, width: 50, height: 50), in: view))
        #expect(CanvasDetail.isVisible(CGRect(x: -5, y: 10, width: 4, height: 4), in: view))   // reaches in at the edge
        #expect(CanvasDetail.isVisible(CGRect(x: 50, y: 50, width: 0, height: 0), in: view))   // a point
        #expect(CanvasDetail.isVisible(CGRect(x: 100, y: 10, width: 5, height: 5), in: view))      // shares only an edge
        #expect(CanvasDetail.isVisible(CGRect(x: 101.5, y: 10, width: 5, height: 5), in: view))    // the stroke reaches in
        #expect(!CanvasDetail.isVisible(CGRect(x: 103, y: 10, width: 5, height: 5), in: view))
        #expect(!CanvasDetail.isVisible(CGRect(x: -20, y: -20, width: 5, height: 5), in: view))
    }

    @Test @MainActor func aHeavyDrawingIsDrawnAsHairlinesAndALightOneIsNot() throws {
        // 1,500 shapes of 100 curves: 150,000 segments, 2.5 to 4 seconds with the full stroker (15 s at 500,000), about half
        // a second as hairlines (measured by hand: the time a drawing takes depends on what else the machine is doing, so
        // the test reads which way it was drawn, and only a catastrophe is a failure on time).
        let heavy = Self.document(blobs: 1500, segments: 100)
        for selectAll in [false, true] {
            let (kd, view) = Self.canvas(heavy, selectAll: selectAll)
            let before = CanvasDetail.hairlineDraws
            let start = ContinuousClock.now
            let png = try #require(AppTestSupport.png(of: view))
            let took = ContinuousClock.now - start
            withExtendedLifetime(kd) {}
            #expect(CanvasDetail.hairlineDraws > before, "selectAll \(selectAll): not drawn as hairlines")
            #expect(took < .seconds(30), "selectAll \(selectAll): drew in \(took)")
            #expect(AppTestSupport.looksDrawn(png))
        }
        let light = Self.document(blobs: 20, segments: 20)
        for selectAll in [false, true] {
            let (kd, view) = Self.canvas(light, selectAll: selectAll)
            let before = CanvasDetail.hairlineDraws
            _ = AppTestSupport.png(of: view)
            withExtendedLifetime(kd) {}
            #expect(CanvasDetail.hairlineDraws == before, "selectAll \(selectAll): a light drawing keeps the full look")
        }
    }

    @Test @MainActor func shapesOutOfViewAreSkippedWithoutChangingWhatIsSeen() throws {
        // Both drawings are heavy (6,600 segments in view); the second also has as many far outside the material.
        let inView = Self.document(blobs: 60, segments: 100)
        var withOffscreen = inView
        for i in 0..<60 { withOffscreen.add(Self.blob(x: 200 + Double(i), y: 5, segments: 100, layer: inView.defaultLayerID)) }
        // The same view for both (the canvas would otherwise fit everything it is given).
        let viewport = CanvasViewport(scale: 45, offset: Vec2(145, 60))
        let a = try Self.render(inView, selectAll: false, viewport: viewport)
        let b = try Self.render(withOffscreen, selectAll: false, viewport: viewport)
        #expect(a == b)
        #expect(AppTestSupport.looksDrawn(a))
    }

    @Test @MainActor func aDragPreviewIsDrawnWhereTheShapeWouldLandWhetherOrNotItStartsInView() throws {
        // A heavy drawing whose selected shapes are far outside the view; dragging them in must show them (and the shapes
        // that start in view and are dragged out must not leave a ghost where they are not).
        var doc = Self.document(blobs: 60, segments: 100)
        for i in 0..<60 { doc.add(Self.blob(x: 200 + Double(i) * 0.5, y: 5, segments: 100, layer: doc.defaultLayerID)) }
        let far = doc.shapes.suffix(60).map(\.id)
        let viewport = CanvasViewport(scale: 45, offset: Vec2(145, 60))
        let kd = LoftLineDocument(project: LoftLineProject(document: doc), toolLibrary: AppTestSupport.library())
        kd.setSelection(far)
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        view.document = kd
        view.layout()
        view.viewport = viewport
        let still = try #require(AppTestSupport.png(of: view))
        let before = CanvasDetail.hairlineDraws
        view.drag = .move(startDoc: Vec2(0, 0), currentDoc: Vec2(-195, 4))
        let dragged = try #require(AppTestSupport.png(of: view))
        #expect(CanvasDetail.hairlineDraws > before)
        #expect(dragged != still, "the selection dragged into view is not drawn")
        view.drag = .none
    }

    @Test @MainActor func aHeavySelectionIsDrawnInTheSelectionColor() throws {
        // Hairlines have no dashed copy over them: the selected shapes are the selection color themselves.
        let doc = Self.document(blobs: 60, segments: 100)
        let plain = try Self.render(doc, selectAll: false)
        let selected = try Self.render(doc, selectAll: true)
        #expect(plain != selected)
    }
}
