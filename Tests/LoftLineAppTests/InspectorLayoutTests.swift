import AppKit
import CADCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The inspector sits under the window toolbar. A scroll view that takes the toolbar as a top content inset makes
/// SwiftUI report its controls' accessibility frames without that inset (52 pt above where they are drawn), so
/// a click or the VoiceOver cursor at the reported frame misses (issue #42). The inspector lays its content out
/// below the toolbar itself instead: its scroll view has no top inset, and the content pads itself by the safe area.
@MainActor
@Suite struct InspectorLayoutTests {
    func scrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll }
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    /// How many pixels of the view's rendering, in rows `rows` (in points from the top), are not transparent.
    func inkedPixels(of host: NSView, rows: ClosedRange<Double>) throws -> Int {
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = Double(rep.pixelsHigh) / Double(host.bounds.height)
        var count = 0
        for y in Int(rows.lowerBound * scale)...min(Int(rows.upperBound * scale), rep.pixelsHigh - 1) {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { count += 1 }
        }
        return count
    }

    func inspectorInWindow() throws -> (NSHostingView<some View>, NSScrollView) {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let host = NSHostingView(rootView: InspectorView(document: doc).environmentObject(doc.toolLibrary))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "inspector-layout-test")
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The tests only mean something if the window really puts something above the content.
        #expect(host.safeAreaInsets.top > 0, Comment(rawValue: "safe area \(host.safeAreaInsets)"))
        return (host, try #require(scrollView(in: host)))
    }

    @Test func theInspectorsScrollViewIsNotInsetByTheToolbar() throws {
        let (_, scroll) = try inspectorInWindow()
        #expect(scroll.contentView.contentInsets.top == 0,
                Comment(rawValue: "the scroll view is inset by \(scroll.contentView.contentInsets.top) pt"))
    }

    /// Without an inset the content has to start below the toolbar by its own padding: nothing is drawn in the band
    /// the toolbar covers, and the content is drawn below it.
    @Test func theContentStartsBelowTheToolbarByItsOwnPadding() throws {
        let (host, _) = try inspectorInWindow()
        let band = host.safeAreaInsets.top
        #expect(try inkedPixels(of: host, rows: 0...(band - 2)) == 0)
        #expect(try inkedPixels(of: host, rows: band...(band + 200)) > 0)
    }
}
