#if DEBUG
import AppKit
import ApplicationServices
import SceneKit
import LoftLineKit

/// Screenshots and text dumps of the app's own windows, taken from inside the process: no Screen
/// Recording or Accessibility permission, and the window does not have to be on screen or in front.
@MainActor
enum HarnessCapture {
    /// The window as drawn, title bar and toolbar included, at the display's scale.
    static func png(of window: NSWindow, scale: CGFloat = 2) -> Data? {
        bitmap(of: window, scale: scale)?.representation(using: .png, properties: [:])
    }

    /// The window as drawn, as a bitmap whose `size` is in points (pixels are `scale` times that).
    static func bitmap(of window: NSWindow, scale: CGFloat = 2) -> NSBitmapImageRep? {
        if let rep = compositorBitmap(of: window) { return rep }
        guard let frameView = window.contentView?.superview else { return nil }
        let bounds = frameView.bounds
        // An explicit 2x bitmap: a window that is not on a display would otherwise be drawn at 1x.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        // SceneKit draws with Metal and comes out blank in cacheDisplay: paste in its own snapshot.
        for scn in descendants(of: frameView).compactMap({ $0 as? SCNView }) where !scn.isHidden {
            var r = frameView.convert(scn.bounds, from: scn)
            if frameView.isFlipped { r.origin.y = bounds.height - r.maxY }
            draw(into: rep) { scn.snapshot().draw(in: r) }
        }
        return rep
    }

    /// The window's pixels as the window server has them: a few milliseconds, Metal content included, so
    /// recordings can run at a real frame rate. Capturing the process's own windows needs no Screen
    /// Recording permission; when the image comes back blank (no permission, window off screen) this
    /// returns nil and the slower in-process drawing is used instead.
    private static func compositorBitmap(of window: NSWindow) -> NSBitmapImageRep? {
        // The window server has only what the app last drew: flush pending drawing first.
        window.displayIfNeeded()
        guard window.windowNumber > 0,
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1, image.height > 1 else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = window.frame.size
        guard let probe = rep.colorAt(x: image.width / 2, y: image.height / 2), probe.alphaComponent > 0.5 else { return nil }
        return rep
    }

    /// Runs `body` drawing into `rep` in point coordinates, origin bottom left.
    private static func draw(into rep: NSBitmapImageRep, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.current = ctx
        // Draw in points: scale the context when it is still in pixels for a bitmap denser than its size.
        let wanted = CGFloat(rep.pixelsWide) / max(rep.size.width, 1)
        let current = abs(ctx.cgContext.ctm.a)
        if abs(wanted - current) > 0.01 { ctx.cgContext.scaleBy(x: wanted / current, y: wanted / current) }
        body()
    }

    /// Scrolls the scroll view under `point` (window coordinates, origin bottom left) so that a target
    /// `offset` points below `point` moves to `point`, in `steps` animated steps. Returns false when no
    /// scroll view is there.
    static func scroll(window: NSWindow, at point: CGPoint, by offset: CGFloat, steps: Int, settle: (Double) async -> Void) async -> Bool {
        guard let content = window.contentView else { return false }
        let scrollViews = descendants(of: content).compactMap { $0 as? NSScrollView }.filter {
            $0.convert($0.bounds, to: nil).contains(point) && $0.documentView != nil
        }
        // The innermost one under the point.
        guard let scrollView = scrollViews.max(by: { descendants(of: $0).count > descendants(of: $1).count }) else { return false }
        let clip = scrollView.contentView
        let start = clip.bounds.origin
        let flipped = scrollView.documentView?.isFlipped ?? true
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let maxY = max(0, docHeight - clip.bounds.height)
        let wanted = min(max(start.y + (flipped ? offset : -offset), 0), maxY)
        for i in 1...max(steps, 1) {
            let t = Double(i) / Double(max(steps, 1))
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            clip.scroll(to: NSPoint(x: start.x, y: start.y + (wanted - start.y) * eased))
            scrollView.reflectScrolledClipView(clip)
            await settle(1.0 / 30)
        }
        return true
    }

    /// The window's scroll views: frame in window points (origin top left), content insets and scroll offset.
    /// Appended to the accessibility dump so a reader can tell where a scroll view really is and how far its
    /// content is inset (SwiftUI reports a scroll view's content frames without the view's own top inset).
    static func scrollViewNotes(of window: NSWindow) -> String {
        guard let content = window.contentView else { return "" }
        let h = window.frame.height
        let lines = descendants(of: content).compactMap { $0 as? NSScrollView }.map { sv -> String in
            let f = sv.convert(sv.bounds, to: nil)
            let clip = sv.contentView
            return String(format: "# scroll view [%d,%d %dx%d] insets top %.0f bottom %.0f, scrolled to %.0f, clip inset top %.0f",
                          Int(f.minX), Int(h - f.maxY), Int(f.width), Int(f.height),
                          sv.contentInsets.top, sv.contentInsets.bottom, clip.bounds.origin.y, clip.contentInsets.top)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    // MARK: Recording frames

    /// What a recorded frame adds to the window: a pointer (window points, origin bottom left) and a caption.
    struct Overlay {
        var pointer: CGPoint?
        /// Draws a click ring around the pointer.
        var pressed = false
        var caption: String?
    }

    /// One frame of a recording: the window with its attached sheet composited where it sits, then the
    /// synthetic pointer and the caption.
    static func frame(of window: NSWindow, overlay: Overlay, scale: CGFloat = 2) -> NSBitmapImageRep? {
        guard let rep = bitmap(of: window, scale: scale) else { return nil }
        let bounds = CGRect(origin: .zero, size: rep.size)
        draw(into: rep) {
            if let sheet = window.attachedSheet, let sheetRep = bitmap(of: sheet, scale: scale) {
                let origin = CGPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
                let image = NSImage(size: sheetRep.size)
                image.addRepresentation(sheetRep)
                image.draw(in: CGRect(origin: origin, size: sheetRep.size))
            }
            if let caption = overlay.caption, !caption.isEmpty { drawCaption(caption, in: bounds) }
            if let p = overlay.pointer { drawPointer(at: p, pressed: overlay.pressed) }
        }
        return rep
    }

    private static func drawCaption(_ text: String, in bounds: CGRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.boundingRect(with: CGSize(width: bounds.width - 120, height: 200), options: [.usesLineFragmentOrigin]).size
        let pad = CGSize(width: 18, height: 10)
        // Near the top, under the toolbar and rulers: the bottom holds the status bar and the 3D playback bar.
        let height = textSize.height + pad.height * 2
        let pill = CGRect(x: bounds.midX - textSize.width / 2 - pad.width, y: bounds.maxY - 84 - height,
                          width: textSize.width + pad.width * 2, height: height)
        NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        string.draw(with: CGRect(x: pill.minX + pad.width, y: pill.minY + pad.height, width: textSize.width, height: textSize.height),
                    options: [.usesLineFragmentOrigin])
    }

    /// A macOS-style arrow pointer with its tip at `p`.
    private static func drawPointer(at p: CGPoint, pressed: Bool) {
        if pressed {
            NSColor(calibratedRed: 0.2, green: 0.5, blue: 1, alpha: 0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)).fill()
        }
        let arrow = NSBezierPath()
        arrow.move(to: p)
        arrow.line(to: CGPoint(x: p.x, y: p.y - 17))
        arrow.line(to: CGPoint(x: p.x + 4.5, y: p.y - 13))
        arrow.line(to: CGPoint(x: p.x + 7.5, y: p.y - 19.5))
        arrow.line(to: CGPoint(x: p.x + 10.5, y: p.y - 18))
        arrow.line(to: CGPoint(x: p.x + 7.5, y: p.y - 11.5))
        arrow.line(to: CGPoint(x: p.x + 12.5, y: p.y - 11.5))
        arrow.close()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowOffset = CGSize(width: 0.5, height: -1)
        shadow.shadowBlurRadius = 2
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setFill()
        arrow.fill()
        NSColor.black.setStroke()
        arrow.lineWidth = 1.2
        arrow.lineJoinStyle = .miter
        arrow.stroke()
    }

    // MARK: Accessibility tree

    /// The accessibility tree of `window` as VoiceOver sees it. SwiftUI only builds its accessibility
    /// nodes for an attached client, so this reads the app's own tree through the Accessibility API
    /// (from a background thread: the main thread has to stay free to answer). That needs the parent
    /// process (your terminal) to be trusted for Accessibility; without it, the sparse in-process view of
    /// the window chrome is returned with a note saying so.
    static func accessibilityTree(of window: NSWindow) async -> String {
        guard AXIsProcessTrusted() else {
            return "# Accessibility is not granted to this process's parent, so only the window chrome is listed.\n"
                + "# Grant Accessibility to your terminal (System Settings > Privacy & Security) for the full tree.\n"
                + accessibilityChrome(of: window)
        }
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: axTree(windowFrame: frame, screenHeight: screenHeight))
            }
        }
    }

    /// Presses the first control under `window` whose title, description, help, identifier or text value contains `text`:
    /// the Accessibility API finds it, then a real mouse click is delivered into the window in-process (AX
    /// actions on the app's own controls fail with "cannot complete"). Returns what was pressed, or nil.
    static func press(text: String, role: String?, in window: NSWindow) async -> String? {
        guard let found = await locate(text: text, role: role, in: window) else { return nil }
        await click(at: found.center, in: window)
        return found.name
    }

    /// Finds the first control under `window` whose title, description, help, identifier or text value contains `text`:
    /// its name and centre in window coordinates (origin bottom left). Needs Accessibility.
    /// SwiftUI adds a freshly shown view's accessibility nodes a moment after it appears, so an exact match
    /// is retried for up to `patience` seconds before a control that merely mentions `text` is accepted.
    static func locate(text: String, role: String?, in window: NSWindow, patience: Double = 3) async -> (name: String, center: CGPoint)? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(patience)
        var loose: (name: String, center: CGPoint)?
        repeat {
            let found = await lookup(text: text, role: role, in: window)
            if let found, found.exact {
                let settled = await settled(found.name, at: found.center, text: text, role: role, in: window)
                return settled
            }
            if let found, loose == nil { loose = (found.name, found.center) }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return loose
    }

    private typealias Hit = (exact: Bool, name: String, center: CGPoint)

    /// One pass over the tree on a background thread. Every attribute read waits on the main thread, and a
    /// tree that will not answer (a sheet's, at times) would otherwise stall the run, so a pass gets 8 s and
    /// then counts as not found; the stuck thread is left behind. (A task group cannot do this: it waits for
    /// the stuck child before it returns.)
    private static func lookup(text: String, role: String?, in window: NSWindow) async -> Hit? {
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let started = Date()
        let hit: Hit? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(axLocate(text: text, role: role, windowFrame: frame, screenHeight: screenHeight))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if once.resume(nil) { print("[harness] accessibility lookup of \"\(text)\" timed out after 8 s") }
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 1500 { print("[harness] lookup of \"\(text)\" took \(ms) ms") }
        return hit
    }

    /// Resumes a continuation from whichever of two threads gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<Hit?, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<Hit?, Never>) { continuation = c }
        /// Returns true when this call did the resuming.
        @discardableResult func resume(_ value: Hit?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let c = continuation else { return false }
            continuation = nil
            c.resume(returning: value)
            return true
        }
    }

    /// SwiftUI reports a view's accessibility frame from its last layout, which can be the one before the
    /// change that showed it: read the control again until two reads agree.
    private static func settled(_ name: String, at center: CGPoint, text: String, role: String?, in window: NSWindow) async -> (name: String, center: CGPoint) {
        var last = center
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let again = await lookup(text: text, role: role, in: window), again.exact else { break }
            if hypot(again.center.x - last.x, again.center.y - last.y) < 1 { return (name, again.center) }
            last = again.center
        }
        return (name, last)
    }

    /// A left click at `point` (window coordinates, origin bottom left). Both events go through the app's event
    /// queue rather than straight to the window: a control that tracks the mouse inside its `mouseDown` (table
    /// rows, SwiftUI gestures) pulls the release from the queue, where a direct `sendEvent` of the press would
    /// wait for a release that never comes. The window has to be key, or the click only tries to focus it.
    static func click(at point: CGPoint, in window: NSWindow) async {
        post(.leftMouseDown, at: point, in: window)
        post(.leftMouseUp, at: point, in: window)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private static var eventNumber = 0

    private static func post(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) {
        eventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                             clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private nonisolated static func axLocate(text: String, role: String?, windowFrame: NSRect,
                                             screenHeight: CGFloat) -> (exact: Bool, name: String, center: CGPoint)? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 5)
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
        func rect(_ e: AXUIElement) -> CGRect? {
            var p = CGPoint.zero, s = CGSize.zero
            guard let pv = attr(e, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID(),
                  let sv = attr(e, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
        let top = screenHeight - windowFrame.maxY
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let root = windows.first(where: {
            guard let r = rect($0) else { return false }
            return abs(r.minX - windowFrame.minX) < 2 && abs(r.minY - top) < 2
        }) ?? windows.first else { return nil }
        let needle = text.lowercased()
        var hit: AXUIElement?
        // A sheet's or alert's tree can loop back on itself: never visit an element twice in one pass.
        var seen = Set<CFHashCode>()
        // A control whose title, description or text is exactly `text` wins over the first one that merely
        // mentions it somewhere (a help string often does).
        func visit(_ e: AXUIElement, depth: Int, exact: Bool) {
            guard hit == nil, depth < 40, seen.insert(CFHash(e)).inserted else { return }
            let matches = exact
                ? [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { str(e, $0).lowercased() == needle }
                : [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXIdentifier", kAXValueAttribute]
                    .contains { str(e, $0).lowercased().contains(needle) }
            if matches, role == nil || str(e, kAXRoleAttribute) == role, str(e, kAXEnabledAttribute) != "0", let r = rect(e), r.width > 0 {
                hit = e
                return
            }
            for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1, exact: exact) }
        }
        visit(root, depth: 0, exact: true)
        seen.removeAll()
        var exact = hit != nil
        // A field named by its label: "Width" with role AXTextField is the first text field after the
        // static text "Width" (SwiftUI's LabeledContent gives the field itself no name).
        if hit == nil, let role, role == "AXTextField" || role == "AXCheckBox" || role == "AXPopUpButton" {
            var order: [AXUIElement] = []
            func flatten(_ e: AXUIElement, depth: Int) {
                guard depth < 40, order.count < 6000, seen.insert(CFHash(e)).inserted else { return }
                order.append(e)
                for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { flatten(child, depth: depth + 1) }
            }
            flatten(root, depth: 0)
            if let i = order.firstIndex(where: { e in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].contains { str(e, $0).lowercased() == needle } }),
               let field = order[(i + 1)...].prefix(6).first(where: { str($0, kAXRoleAttribute) == role }) {
                hit = field
                exact = true
            }
            seen.removeAll()
        }
        if hit == nil { visit(root, depth: 0, exact: false) }
        guard let hit, let r = rect(hit) else { print("[harness] press: nothing matched \"\(text)\""); return nil }
        // Screen top-left origin to window bottom-left origin.
        let center = CGPoint(x: r.midX - windowFrame.minX, y: (screenHeight - r.midY) - windowFrame.minY)
        let name = [str(hit, kAXTitleAttribute), str(hit, kAXDescriptionAttribute), str(hit, kAXValueAttribute)].first { !$0.isEmpty }
            ?? str(hit, "AXIdentifier")
        return (exact, "\(str(hit, kAXRoleAttribute)) \"\(name)\"", center)
    }

    private nonisolated static func axTree(windowFrame: NSRect, screenHeight: CGFloat) -> String {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 5)
        func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func text(_ e: AXUIElement, _ name: String) -> String {
            guard let v = attr(e, name) else { return "" }
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return ""
        }
        func frame(_ e: AXUIElement) -> CGRect? {
            var p = CGPoint.zero, s = CGSize.zero
            guard let pv = attr(e, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID(),
                  let sv = attr(e, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &s)
            return CGRect(origin: p, size: s)
        }
        // AX frames are in screen points with the origin at the top left; NSWindow's are bottom left.
        let top = screenHeight - windowFrame.maxY
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var lines: [String] = []
        lines.append("# window at \(Int(windowFrame.minX)),\(Int(top)) \(Int(windowFrame.width))x\(Int(windowFrame.height)) (screen points, origin top left); "
            + "accessibility lists \(windows.count) window(s): "
            + windows.map { w in
                let f = frame(w) ?? .zero
                return "\(text(w, kAXRoleAttribute)) \"\(text(w, kAXTitleAttribute))\" [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
            }.joined(separator: ", "))
        guard let root = windows.first(where: {
            guard let f = frame($0) else { return false }
            return abs(f.minX - windowFrame.minX) < 2 && abs(f.minY - top) < 2 && abs(f.width - windowFrame.width) < 2
        }) ?? windows.first else { return lines.joined(separator: "\n") + "\n# no accessibility window found\n" }
        let origin = frame(root)?.origin ?? .zero

        // An open alert's tree can loop back on itself; bound the depth (this runs on a small background
        // stack) and skip elements already seen.
        var seen = Set<CFHashCode>()
        func visit(_ e: AXUIElement, depth: Int) {
            guard lines.count < 6000, depth < 60, seen.insert(CFHash(e)).inserted else { return }
            var line = String(repeating: "  ", count: depth) + text(e, kAXRoleAttribute)
            let sub = text(e, kAXSubroleAttribute)
            if !sub.isEmpty { line += "/" + sub }
            for (label, key) in [("title", kAXTitleAttribute), ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute),
                                 ("value", kAXValueAttribute), ("id", "AXIdentifier")] {
                let v = text(e, key)
                if !v.isEmpty { line += " \(label)=\"\(v.prefix(90))\"" }
            }
            if text(e, kAXEnabledAttribute) == "0" { line += " DISABLED" }
            if let f = frame(e) {
                line += "  [\(Int(f.minX - origin.x)),\(Int(f.minY - origin.y)) \(Int(f.width))x\(Int(f.height))]"
            }
            lines.append(line)
            for child in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The accessibility tree under `window`, one element per line: role, label, value, help and the
    /// frame in window points (origin top left). This is what VoiceOver sees.
    private static func accessibilityChrome(of window: NSWindow) -> String {
        var lines: [String] = []
        let origin = window.frame
        func visit(_ object: Any, depth: Int) {
            guard lines.count < 6000 else { return }
            let element = object as AnyObject
            let a = element as? NSAccessibilityProtocol
            let role = a?.accessibilityRole()?.rawValue ?? String(describing: type(of: element))
            var line = String(repeating: "  ", count: depth) + role
            if let sub = a?.accessibilitySubrole()?.rawValue { line += "/" + sub }
            if let label = a?.accessibilityLabel(), !label.isEmpty { line += " label=\"\(label.prefix(90))\"" }
            if let title = a?.accessibilityTitle(), !title.isEmpty { line += " title=\"\(title.prefix(90))\"" }
            if let value = a?.accessibilityValue() {
                let text = "\(value)"
                if !text.isEmpty { line += " value=\"\(text.prefix(90))\"" }
            }
            if let help = a?.accessibilityHelp(), !help.isEmpty { line += " help=\"\(help.prefix(70))\"" }
            if a?.isAccessibilityEnabled() == false { line += " DISABLED" }
            if let f = a?.accessibilityFrame(), f.width > 0 || f.height > 0 {
                let x = Int(f.minX - origin.minX), y = Int(origin.maxY - f.maxY)
                line += "  [\(x),\(y) \(Int(f.width))x\(Int(f.height))]"
            }
            lines.append(line)
            for child in a?.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        visit(window, depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Menus

    /// The menu bar: titles, enabled state and key equivalents, as validated for the current focus.
    static func menuDump() -> String {
        guard let main = NSApp.mainMenu else { return "(no main menu)\n" }
        var lines: [String] = []
        func visit(_ menu: NSMenu, depth: Int) {
            menu.update()
            for item in menu.items {
                let pad = String(repeating: "  ", count: depth)
                if item.isSeparatorItem { lines.append(pad + "---"); continue }
                var line = pad + item.title
                if !item.isEnabled { line += "  (disabled)" }
                let key = keyText(item)
                if !key.isEmpty { line += "  \(key)" }
                if item.state == .on { line += "  ✓" }
                lines.append(line)
                if let sub = item.submenu { visit(sub, depth: depth + 1) }
            }
        }
        for item in main.items {
            lines.append("[\(item.title)]")
            if let sub = item.submenu { visit(sub, depth: 1) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func keyText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + item.keyEquivalent.uppercased()
    }
}
#endif
