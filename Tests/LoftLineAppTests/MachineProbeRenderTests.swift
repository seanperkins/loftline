import AppKit
import CADCore
import Foundation
import PostCore
import SwiftUI
import Testing
@testable import LoftLineApp

/// The Machines editor's park-and-probe section draws with probing on, for each controller.
@Suite struct MachineProbeRenderTests {
    @Test @MainActor func probeSectionRenders() throws {
        for base in BuiltInMachines.all {
            var m = base
            var probe = ToolChangeProbe.defaults(for: m)
            probe.probeTravel = probe.plateThickness * 2   // one problem shown as the user types
            m.toolChangeProbe = probe
            let view = MachineEditor(machine: .constant(m), editable: true, posts: BuiltInPosts.all, onSave: { _ in }, onDelete: { _ in })
                .frame(width: 560, height: 1100)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 1100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(AppTestSupport.looksDrawn(png))
            if let dir = ProcessInfo.processInfo.environment["LOFTLINE_RENDER_DIR"] {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("machine-probe-\(m.id).png"))
            }
        }
    }
}
