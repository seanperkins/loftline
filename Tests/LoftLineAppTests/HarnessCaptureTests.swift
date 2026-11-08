import AppKit
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

#if DEBUG
@Suite struct HarnessCaptureTests {
    @Test @MainActor func aWindowIsCapturedAtTwiceItsSizeWithItsContent() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Color(red: 1, green: 0, blue: 0).frame(width: 200, height: 120))
        let png = try #require(HarnessCapture.png(of: window))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == Int(window.frame.width * 2))
        #expect(rep.pixelsHigh == Int(window.frame.height * 2))
        // The middle of the window is inside the red content, not the title bar.
        let c = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2 + 20)?.usingColorSpace(.sRGB))
        #expect(c.redComponent > 0.8 && c.greenComponent < 0.25 && c.blueComponent < 0.25)
    }

    @Test @MainActor func theMenuDumpListsTitlesEnabledStateAndKeys() {
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        let main = NSMenu()
        let top = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Test")
        sub.autoenablesItems = false
        let open = NSMenuItem(title: "Open…", action: #selector(NSObject.description), keyEquivalent: "o")
        open.keyEquivalentModifierMask = [.command, .shift]
        let off = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        off.isEnabled = false
        sub.addItem(open); sub.addItem(.separator()); sub.addItem(off)
        top.submenu = sub
        main.addItem(top)
        NSApp.mainMenu = main
        let dump = HarnessCapture.menuDump()
        #expect(dump.contains("[Test]"))
        #expect(dump.contains("Open…  ⇧⌘O"))
        #expect(dump.contains("Off  (disabled)"))
        #expect(dump.contains("---"))
    }
}
#endif
