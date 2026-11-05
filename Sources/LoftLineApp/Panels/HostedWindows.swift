import AppKit
import SwiftUI
import LoftLineKit

/// App-level utility windows (Help, Welcome) hosted in plain NSWindows, so they can be opened
/// from anywhere — menus, sheets, the app delegate at launch — without a SwiftUI scene context.
enum HostedWindows {
    private static var windows: [String: NSWindow] = [:]

    static func show<V: View>(id: String, title: String, size: CGSize, resizable: Bool = true,
                              content: () -> V) {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        w.setFrameAutosaveName("LoftLine." + id)
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    static func close(id: String) { windows[id]?.close() }
}
