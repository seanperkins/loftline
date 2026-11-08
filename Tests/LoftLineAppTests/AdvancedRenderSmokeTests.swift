import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Offscreen renders of the advanced toolpath UI (sheets, sidebar summary, tab editor) to catch
/// crashes and blank output. Set LOFTLINE_RENDER_DIR to keep the PNGs.
@Suite struct AdvancedRenderSmokeTests {
    /// Profile (with manual tabs, under tab editing), V-Carve and Pocket, all calculated.
    @MainActor func document() -> LoftLineDocument {
        var p = AppTestSupport.project()
        let a = p.document.shapes[0], b = p.document.shapes[1]
        var profile = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [a.id])!
        var tabs = TabSettings(isEnabled: true)
        tabs = TabEditor.adding(at: Vec2(2, 1), to: tabs, shapes: [a], maxDistance: 0.1, tolerance: 0.001)!
        tabs = TabEditor.adding(at: Vec2(3, 1.5), to: tabs, shapes: [a], maxDistance: 0.1, tolerance: 0.001)!
        profile = profile.withProfileTabs(tabs)
        p.operations = [profile,
                        OperationFactory.make(kind: .vcarve, project: p, library: .seeded, shapeIDs: [b.id])!,
                        OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [b.id])!]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        doc.calculateNow(p.operations.map(\.id))
        doc.sidebarTab = .toolpaths
        doc.selectedOperationID = profile.id
        doc.tabEditingOperationID = profile.id
        return doc
    }

    @MainActor func render<V: View>(_ view: V, _ name: String, size: NSSize) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return data
    }

    @Test @MainActor func sheetsRender() throws {
        let doc = document()
        doc.setSelection([doc.document.shapes[0].id])
        let form = ModelPlacementForm(mesh: ModelPlacementFormTests.mesh, name: "Pyramid", job: doc.document.job,
                                      library: doc.mergedLibrary)
        let views: [(AnyView, String, NSSize)] = [
            (AnyView(InlayWizardSheet(document: doc)), "inlay-wizard.png", NSSize(width: 560, height: 680)),
            (AnyView(ModelPlacementSheet(document: doc, form: form)), "place-model.png", NSSize(width: 520, height: 680)),
            (AnyView(SaveAllToolpathsSheet(document: doc)), "save-all.png", NSSize(width: 620, height: 600)),
            (AnyView(ValidationSheet(document: doc)), "validation.png", NSSize(width: 640, height: 560)),
            (AnyView(ProductionPlatesSheet(document: doc)), "production-plates.png", NSSize(width: 480, height: 720)),
        ]
        for (v, name, size) in views {
            let data = try render(v.environmentObject(doc.toolLibrary), name, size: size)
            #expect(AppTestSupport.looksDrawn(data), Comment(rawValue: name))
        }
    }

    @Test @MainActor func toolpathPanelsRender() throws {
        let doc = document()
        let sidebar = try render(SidebarView(document: doc).environmentObject(doc.toolLibrary), "toolpaths-sidebar.png",
                                 size: NSSize(width: 300, height: 700))
        #expect(AppTestSupport.looksDrawn(sidebar))
        let inspector = try render(InspectorView(document: doc).environmentObject(doc.toolLibrary), "profile-inspector.png",
                                   size: NSSize(width: 320, height: 1400))
        #expect(AppTestSupport.looksDrawn(inspector))
        for (i, op) in doc.project.operations.enumerated() {
            doc.selectedOperationID = op.id
            let d = try render(InspectorView(document: doc).environmentObject(doc.toolLibrary), "inspector-\(i).png",
                               size: NSSize(width: 320, height: 1200))
            #expect(AppTestSupport.looksDrawn(d), "inspector \(i)")
        }
    }

    @Test @MainActor func canvasDrawsTabEditor() throws {
        let doc = document()
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view.document = doc
        view.layout()
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tab-editor.png"))
        }
        #expect(AppTestSupport.looksDrawn(data))
    }
}
