import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Renders the canvas and the main window offscreen to catch drawing crashes and blank output.
/// Set LOFTLINE_RENDER_DIR to keep the PNGs for inspection.
@Suite struct RenderSmokeTests {
    func sampleDocument() -> LoftLineDocument {
        var p = AppTestSupport.project()
        let layer = p.document.defaultLayerID
        p.document.add(Shape(name: "Circle", layerID: layer, paths: [ShapeFactory.circle(center: Vec2(12, 9), radius: 3)]))
        p.document.add(Shape(name: "Star", layerID: layer,
                             paths: [ShapeFactory.star(center: Vec2(19, 12), points: 5, outerRadius: 2.5, innerRadius: 1)]))
        p.document.job.xyOrigin = .center
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.setSelection([p.document.shapes[2].id])
        // A fake calculated toolpath so the overlay is exercised.
        let op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[2].id])!
        doc.perform("add") { $0.operations = [op] }
        let coords = MachineCoordinates(job: doc.document.job)
        let c = coords.machineXY(Vec2(12, 9))
        let tp = Toolpath(name: "t", kind: .profile, tool: ToolLibrary.seeded.tools[0], moves: [
            .rapid(to: Vec3(Vec2(0, 0), z: coords.safeZ)),
            .rapid(to: Vec3(c + Vec2(3.125, 0), z: coords.safeZ)),
            .linear(to: Vec3(c + Vec2(3.125, 0), z: coords.z(depth: 0.375)), feed: 30),
            .arcCCW(to: Vec3(c + Vec2(-3.125, 0), z: coords.z(depth: 0.375)), center: c, feed: 100),
            .arcCCW(to: Vec3(c + Vec2(3.125, 0), z: coords.z(depth: 0.375)), center: c, feed: 100),
            .rapid(to: Vec3(c + Vec2(3.125, 0), z: coords.safeZ)),
        ])
        doc.results[op.id] = ToolpathResult(toolpaths: [tp], error: nil, operation: op,
                                            designRevision: doc.designRevision, estimatedSeconds: 90)
        return doc
    }

    func png(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func keep(_ data: Data, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] else { return }
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    @Test @MainActor func canvasRendersNonBlank() throws {
        let doc = sampleDocument()
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view.document = doc
        view.layout()
        view.hoverDoc = Vec2(5, 5)
        let data = try #require(png(view))
        keep(data, "canvas.png")
        let rep = try #require(NSBitmapImageRep(data: data))
        // Sample the material centre-ish region: it must not be the background colour everywhere.
        var colours = Set<String>()
        for x in stride(from: 50, to: rep.pixelsWide, by: 37) {
            for y in stride(from: 50, to: rep.pixelsHigh, by: 41) {
                if let c = rep.colorAt(x: x, y: y) { colours.insert(c.description) }
            }
        }
        #expect(colours.count > 3)
    }

    @Test @MainActor func mainWindowRenders() throws {
        let doc = sampleDocument()
        let root = ContentView(document: doc).environmentObject(doc.toolLibrary)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1300, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        let data = try #require(png(host))
        keep(data, "window.png")
        #expect(AppTestSupport.looksDrawn(data))
    }
}
