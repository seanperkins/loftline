import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp

/// Offscreen renders of the app-ux windows and the side-by-side view, to catch layout crashes.
@Suite struct AppUXRenderTests {
    @MainActor func render<V: View>(_ view: V, size: CGSize) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @Test func centerModes() {
        #expect(CenterMode.split.showsDesign && CenterMode.split.showsPreview)
        #expect(CenterMode.design2D.showsDesign && !CenterMode.design2D.showsPreview)
        #expect(!CenterMode.preview3D.showsDesign && CenterMode.preview3D.showsPreview)
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        doc.centerMode = .split
        doc.showDesignCanvas()
        #expect(doc.centerMode == .split)  // already visible: the split stays
        doc.centerMode = .preview3D
        doc.showDesignCanvas()
        #expect(doc.centerMode == .design2D)
    }

    @Test @MainActor func splitViewRenders() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        doc.centerMode = .split
        let data = try #require(render(ContentView(document: doc).environmentObject(doc.toolLibrary),
                                       size: CGSize(width: 1400, height: 800)))
        #expect(AppTestSupport.looksDrawn(data))
    }

    /// The Help window as the macOS 15 hosted runner drew it (probe run 40534368182): only the search field. Without a
    /// displayed window the sidebar list and the topic text are not realised, so the render scores 2 colours at the
    /// default sampling. A finer sampling still tells it from a blank panel.
    @Test func aSparseHostedRunnerRenderIsNotBlankAtAFinerSampling() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LoftLineApp/hosted-runner-help-render.png")
        let png = try Data(contentsOf: url)
        #expect(!AppTestSupport.looksDrawn(png), "the default sampling scores this render 2")
        #expect(AppTestSupport.looksDrawn(png, step: AppTestSupport.finerStep))
    }

    @Test func aFlatImageIsBlankAtEverySampling() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try #require(rep.bitmapData), 255, rep.bytesPerRow * rep.pixelsHigh)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(!AppTestSupport.looksDrawn(png))
        #expect(!AppTestSupport.looksDrawn(png, step: AppTestSupport.finerStep))
    }

    @Test @MainActor func utilityWindowsRender() throws {
        let suite = "loftline-tests-render-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let prefs = PreferencesModel(defaults: UserDefaults(suiteName: suite)!)
        #expect(AppTestSupport.looksDrawn(try #require(render(PreferencesView(model: prefs), size: CGSize(width: 640, height: 480)))))
        // On a hosted runner the Help window draws only its search field, so it is sampled more finely there; on a
        // development Mac it keeps the default sampling and must show the sidebar and the topic as well.
        #expect(AppTestSupport.looksDrawn(try #require(render(HelpView(), size: CGSize(width: 860, height: 600))),
                                          step: AppTestSupport.onHostedRunner ? AppTestSupport.finerStep : 23))
        #expect(AppTestSupport.looksDrawn(try #require(render(WelcomeView(preferences: prefs), size: CGSize(width: 720, height: 520)))))
    }
}
