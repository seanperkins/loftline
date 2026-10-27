#if DEBUG
import AppKit
import CADCore
import CAMCore
import SwiftUI

/// A scripted, headless-friendly UI driver for debug builds.
///
///     LoftLine --ui-scenario harness/scenarios/profile.json --ui-out .tmp/ui/run [--ui-active 1]
///
/// Every flag takes a value: AppKit reads `-key value` pairs from the arguments, and a bare flag shifts the
/// pairing so the next value ("YES") is taken for a file to open.
///
/// It opens an untitled document, runs the scenario's steps against the live app, writes PNGs and text
/// dumps (accessibility tree, menus) or recorded frames taken from inside the process, then exits. Nothing
/// needs Screen Recording or Accessibility permission, the window does not need to be on screen, and
/// `scripts/ui.sh` gives the run its own HOME, which keeps its tools and recovery files apart from yours; preferences are
/// not isolated, because UserDefaults ignores HOME.
/// See `docs/UI-HARNESS.md`.
@MainActor
final class UIHarness {
    static let shared = UIHarness()

    struct Request {
        var scenario: URL
        var out: URL
        /// Make the app active, so the window is drawn as the key window (coloured traffic lights and selection).
        var active: Bool
        /// Make the window key without activating the app: it draws as key and takes clicks, and the person
        /// using the Mac keeps their focus. What recordings use.
        var key: Bool
        /// Park the window just past the edge of its screen, where it is not in the way; recordings still see it.
        var offscreen: Bool
        /// Overrides of the scenario's appearance ("light", "dark") and window size, from the command line.
        var appearance: String?
        var size: [Double]?
    }

    static var request: Request? {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let scenario = value(after: "--ui-scenario") else { return nil }
        let out = value(after: "--ui-out") ?? ".tmp/ui/run"
        let size = value(after: "--ui-size").map { $0.split(separator: "x").compactMap { Double($0) } }
        return Request(scenario: URL(fileURLWithPath: scenario), out: URL(fileURLWithPath: out, isDirectory: true),
                       active: value(after: "--ui-active") == "1", key: value(after: "--ui-key") == "1",
                       offscreen: value(after: "--ui-offscreen") == "1",
                       appearance: value(after: "--ui-appearance"),
                       size: size?.count == 2 ? size : nil)
    }

    static var isActive: Bool { request != nil }

    private weak var document: LoftLineDocument?
    private var log: [String] = []
    private var outDir = URL(fileURLWithPath: ".")

    // Recording state: the clip being written, the synthetic pointer (main-window points, origin bottom
    // left), whether it is mid-click, and the caption along the bottom of each frame.
    private var recorder: HarnessRecorder?
    private var pointer: CGPoint?
    private var pressed = false
    private var caption: String?

    /// Called when a document window appears.
    func noteDocument(_ doc: LoftLineDocument) { if document == nil { document = doc } }

    func start() {
        guard let request = Self.request else { return }
        outDir = request.out
        // Never hang a run, even if the main thread is blocked: this watchdog is on its own thread.
        let log = outDir.appendingPathComponent("harness.log")
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            if let h = FileHandle(forWritingAtPath: log.path) {
                h.seekToEndOfFile()
                h.write(Data("timed out after 180 s (the main thread may be blocked)\n".utf8))
            }
            print("[harness] finished: timed out after 180 s")
            _exit(2)
        }
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                let scenario = try HarnessScenario.parse(Data(contentsOf: request.scenario))
                try await run(scenario, request: request)
                finish("ok", code: 0)
            } catch {
                if let r = recorder { _ = await r.stop(); recorder = nil }
                finish("\(error)", code: 1)
            }
        }
    }

    private func say(_ text: String) {
        log.append(text)
        print("[harness] \(text)")
        fflush(stdout)
        // Written as it goes, so a run the watchdog ends still shows how far it got.
        try? (log.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("harness.log"), atomically: true, encoding: .utf8)
    }

    private func finish(_ status: String, code: Int32) {
        say("finished: \(status)")
        try? (log.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("harness.log"), atomically: true, encoding: .utf8)
        exit(code)
    }

    // MARK: Running

    private func run(_ scenario: HarnessScenario, request: Request) async throws {
        apply(appearance: request.appearance ?? scenario.appearance ?? "system")
        if document == nil { NSDocumentController.shared.newDocument(nil) }
        try await waitUntil("a document window") { self.document != nil && self.window != nil }
        let window = try requireWindow()
        if let s = request.size ?? scenario.window { window.setContentSize(NSSize(width: s[0], height: s[1])) }
        wantsKey = request.active || request.key
        await place(window, offscreen: request.offscreen)
        if request.active {
            await makeKey(window)
        } else if request.key {
            await pretendKey(window)
        }
        await settle()
        say("windows \(NSApp.windows.count), this one visible \(window.isVisible), on active space \(window.isOnActiveSpace), "
            + "occlusion \(window.occlusionState.contains(.visible) ? "visible" : "hidden"), ax trusted \(AXIsProcessTrusted()), "
            + "ax children \(window.accessibilityChildren()?.count ?? -1), app ax windows \(NSApp.accessibilityWindows()?.count ?? -1)")
        say("window \(Int(window.frame.width))x\(Int(window.frame.height)) at \(Int(window.frame.minX)),\(Int(window.frame.minY)); "
            + "appearance \(window.effectiveAppearance.name.rawValue); screen \(Int(window.screen?.backingScaleFactor ?? 0))x of "
            + NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.backingScaleFactor))x" }.joined(separator: ", "))
        for (i, step) in scenario.steps.enumerated() {
            say("step \(i + 1): \(step.op)")
            try await perform(step)
            // The title bar falls back to its inactive look on some redraws; remind it after the steps that
            // redraw a lot. Not after input steps: the notification re-renders SwiftUI, which resets a field
            // being typed into.
            let redraws: Set<String> = ["sample", "project", "appearance", "size", "mode", "tab", "sheet", "closeSheet", "import", "calculate", "selectToolpath", "select", "fit"]
            if redraws.contains(step.op) { await remindKey() }
        }
        if let r = recorder {
            let s = await r.stop()
            recorder = nil
            say("wrote \(r.name).ffconcat (\(s.count) frames, \(String(format: "%.1f", s.seconds)) s; the scenario never ended the recording)")
        }
    }

    /// Whether the run asked for an active app (`--ui-active 1`).
    private var wantsKey = false

    /// Brings the app to the front and makes `window` key, retrying for a moment: macOS grants activation
    /// to a background process only sometimes, and a click on a window that is not key selects nothing.
    private func makeKey(_ window: NSWindow) async {
        let deadline = Date().addingTimeInterval(2.5)
        repeat {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            await settle(0.25)
        } while !(window.isKeyWindow && NSApp.isActive) && Date() < deadline
        say(window.isKeyWindow && NSApp.isActive ? "window is key" : "window is NOT key (macOS did not activate the app; clicks may only focus)")
    }

    /// Puts the window on the densest screen that actually shows it (a dark or covered display hides the
    /// window from the accessibility server as well as from the recording), centred, or parked just past
    /// the screen's edge when `offscreen` is set.
    private func place(_ window: NSWindow, offscreen: Bool) async {
        let screens = NSScreen.screens.sorted { $0.backingScaleFactor > $1.backingScaleFactor }
        for screen in screens {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.midX - window.frame.width / 2, y: v.midY - window.frame.height / 2))
            if offscreen { park(window, on: screen) }
            window.orderFrontRegardless()
            await settle(0.4)
            if window.occlusionState.contains(.visible) {
                say("window on the \(Int(screen.backingScaleFactor))x screen at \(Int(window.frame.minX)),\(Int(window.frame.minY))"
                    + (offscreen ? " (parked past its edge)" : ""))
                return
            }

        }
        say(Self.screenIsLocked
            ? "the screen is locked: frames still record, but press, move and scroll cannot find controls until it is unlocked"
            : "no screen shows the window (covered or dark); frames still record, control lookups may fail")
    }

    /// Whether the login session's screen is locked or the screen saver is up: every window is then hidden
    /// from the accessibility server, so control lookups fail.
    static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Moves the window so that only a sliver of it stays on `screen`, on a side where no other screen
    /// continues, and floats it so nothing covers that sliver: out of the way, but still on screen.
    private func park(_ window: NSWindow, on screen: NSScreen) {
        let f = window.frame, sf = screen.frame, keep: CGFloat = 4
        let candidates = [
            NSRect(x: sf.maxX - keep, y: f.minY, width: f.width, height: f.height),
            NSRect(x: sf.minX - f.width + keep, y: f.minY, width: f.width, height: f.height),
            NSRect(x: f.minX, y: sf.minY - f.height + keep, width: f.width, height: f.height),
        ]
        for c in candidates where !NSScreen.screens.contains(where: { $0 !== screen && $0.frame.intersects(c) }) {
            window.setFrameOrigin(c.origin)
            window.level = .floating
            return
        }
        say("no free edge on this screen to park the window; leaving it in place")
    }

    /// Re-posts the key and main notifications for a pretend-key window, so the title bar draws as key again.
    private func remindKey() async {
        guard wantsKey, !NSApp.isActive, let w = window, !w.isKeyWindow else { return }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: w)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: w)
        await settle(0.25)
    }

    /// Key status without activation: the window believes it is key and main (so its title bar, selection and
    /// clicks behave as in front), while the app that has the user's focus keeps it.
    private func pretendKey(_ window: NSWindow) async {
        window.becomeMain()
        window.becomeKey()
        // An inactive app cannot have a key window, but the views only listen for these notifications.
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await settle(0.3)
        say(window.isKeyWindow ? "window is key (without activating the app)" : "window drawn as key (the app stays in the background; clicks reach buttons, not table rows)")
    }

    private var window: NSWindow? {
        NSDocumentController.shared.documents.compactMap { $0.windowControllers.first?.window }.first { $0.isVisible || $0.contentView != nil }
    }

    private func requireWindow() throws -> NSWindow {
        guard let w = window else { throw HarnessError(message: "no document window") }
        return w
    }

    private func requireDocument() throws -> LoftLineDocument {
        guard let d = document else { throw HarnessError(message: "no document") }
        return d
    }

    private func apply(appearance: String) {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private func perform(_ step: HarnessScenario.Step) async throws {
        let doc = try requireDocument()
        switch step.op {
        case "sample":
            guard let url = SampleProjects.url(for: SampleProjects.sign) else { throw HarnessError(message: "the sample sign was not found") }
            let project = try LoftLineProject.opening(from: Data(contentsOf: url))
            doc.perform("Load sample") { $0 = project }
            doc.setSelection([])
            doc.requestCanvas(.fit)
            await settle()
        case "project":
            let path = step.name ?? ""
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw HarnessError(message: "project: no file at \(url.path)") }
            let project = try LoftLineProject.opening(from: Data(contentsOf: url))
            doc.perform("Load project") { $0 = project }
            doc.setSelection([])
            doc.requestCanvas(.fit)
            await settle()
        case "appearance":
            apply(appearance: step.value ?? "system")
            // A window already on screen keeps its look until told: set it on the window too and redraw.
            let w = try requireWindow()
            w.appearance = NSApp.appearance
            w.attachedSheet?.appearance = NSApp.appearance
            await settle()
            w.display()
            await settle(0.5)
        case "size":
            let s = step.size ?? [1000, 640]
            try requireWindow().setContentSize(NSSize(width: s[0], height: s[1]))
            await settle()
        case "mode":
            doc.centerMode = ["2d": CenterMode.design2D, "split": .split, "3d": .preview3D][step.value ?? ""] ?? .design2D
            await settle()
        case "fit":
            doc.requestCanvas(step.value == "selection" ? .fitSelection : .fit)
            await settle()
        case "tab":
            doc.sidebarTab = step.value == "toolpaths" ? .toolpaths : .design
            await settle()
        case "tool":
            guard let tool = CanvasTool(rawValue: step.value ?? "") else {
                throw HarnessError(message: "unknown tool \"\(step.value ?? "")\"; tools: " + CanvasTool.allCases.map(\.rawValue).joined(separator: ", "))
            }
            doc.activeTool = tool
            await settle()
        case "select":
            let wanted = Set(step.names ?? [])
            let ids = doc.project.document.shapes.filter { wanted.contains($0.name) }.map(\.id)
            guard !ids.isEmpty else {
                throw HarnessError(message: "no shape named \(wanted.sorted()); shapes: "
                    + Set(doc.project.document.shapes.map(\.name)).sorted().joined(separator: ", "))
            }
            if ids.count == 1, let name = step.names?.first { await pointAndFlash(at: name, role: nil) }
            doc.setSelection(ids)
            await settle()
        case "selectToolpath":
            guard let op = doc.project.operations.first(where: { $0.setup.name == step.name }) else {
                throw HarnessError(message: "no toolpath named \"\(step.name ?? "")\"; toolpaths: "
                    + doc.project.operations.map(\.setup.name).joined(separator: ", "))
            }
            doc.sidebarTab = .toolpaths
            if doc.selectedOperationID != op.id { await pointAndFlash(at: op.setup.name, role: "AXStaticText") }
            doc.selectedOperationID = op.id
            await settle()
        case "calculate":
            doc.calculateAll()
            try await waitUntil("toolpaths to calculate", timeout: 40) {
                doc.calculating.isEmpty && !doc.results.isEmpty
            }
            await settle(0.8)
        case "editTool":
            guard let op = doc.project.operations.first, var tool = doc.toolLibrary.library.tool(id: op.setup.toolID) else {
                throw HarnessError(message: "there is no toolpath whose tool could be edited")
            }
            switch step.value {
            case "rename": tool.name += " (renamed)"
            case "describe": tool.notes = "Roughing, upcut\nSecond line of notes"
            case "rpm": tool.spindleRPM = 60000
            case "number":
                guard let other = doc.toolLibrary.library.tools.first(where: { $0.id != tool.id }) else {
                    throw HarnessError(message: "there is no other tool to share a number with")
                }
                tool.number = other.number
            default: tool.diameter += doc.units == .inch ? 0.0625 : 1.5
            }
            doc.toolLibrary.update(tool)
            await settle(1.0)
        case "selectTool":
            NotificationCenter.default.post(name: .harnessSelectTool, object: step.name)
            await settle(0.8)
        case "editToolpath":
            guard let op = doc.project.operations.first(where: { step.name == nil || $0.setup.name == step.name }) else {
                throw HarnessError(message: "no toolpath named \"\(step.name ?? "")\"")
            }
            var edited = op
            switch (edited, step.value) {
            case (.profile(var o), "deeper"): o.params.depth.cutDepth = doc.project.document.job.thickness + 0.5; edited = .profile(o)
            case (.pocket(var o), "deeper"): o.params.depth.cutDepth = doc.project.document.job.thickness + 0.5; edited = .pocket(o)
            case (.profile(var o), "tabs"):
                o.params.tabs.isEnabled = true
                o.params.tabs.thickness = o.params.depth.cutDepth - o.params.depth.startDepth
                edited = .profile(o)
            default: throw HarnessError(message: "\(step.value ?? "") does not apply to a \(op.kind.displayName) toolpath")
            }
            doc.updateOperationLive(edited)
            await settle(0.8)
        case "searchTools":
            NotificationCenter.default.post(name: .harnessSearchTools, object: step.value ?? "")
            await settle(0.8)
        case "captureWindow":
            let title = step.value ?? ""
            try await waitUntil("the \(title) window") { NSApp.windows.contains { $0.title == title && $0.isVisible } }
            guard let other = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
                throw HarnessError(message: "no window titled \(title)")
            }
            await settle(0.8)
            try await write(window: other, stem: step.name ?? "window")
        case "sheet":
            doc.sheet = try sheet(named: step.value ?? "")
            try await waitUntil("a sheet") { self.window?.attachedSheet != nil }
            await settle(0.9)
        case "fileTarget":
            PanelRunner.harnessTarget = (step.name ?? "").isEmpty ? nil : URL(fileURLWithPath: step.name ?? "")
        case "closeSheet":
            PanelRunner.harnessTarget = nil
            doc.sheet = nil
            doc.alert = nil
            doc.deferredAlert = nil
            await settle(0.7)
        case "import":
            let path = step.name ?? ""
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw HarnessError(message: "import: no file at \(url.path)") }
            doc.importFiles([url])
            await settle(0.9)
        case "key":
            guard let key = HarnessScenario.keys[step.value ?? ""] else { throw HarnessError(message: "unknown key") }
            let target = try requireWindow().attachedSheet ?? requireWindow()
            if step.value == "selectAll", let editor = target.firstResponder as? NSTextView {
                // A window that is not key has no key equivalents: select the focused field's text directly.
                editor.selectAll(nil)
            } else {
                send(characters: key.chars, keyCode: key.code, command: key.command, to: target)
            }
            await settle(0.7)
        case "type":
            let target = try requireWindow().attachedSheet ?? requireWindow()
            for ch in step.value ?? "" {
                send(characters: String(ch), keyCode: Self.keyCodes[ch] ?? 0, to: target)
                await settle(recorder == nil ? 0.02 : 0.08)
            }
            await settle(0.3)
        case "expand":
            UserDefaults.standard.set(true, forKey: SectionState.key(for: step.name ?? ""))
            await settle()
        case "press", "move":
            let main = try requireWindow()
            let win = main.attachedSheet ?? main
            guard let found = await HarnessCapture.locate(text: step.name ?? "", role: step.value, in: win) else {
                throw HarnessError(message: "no control matching \"\(step.name ?? "")\" could be found" + Self.lookupHint)
            }
            // The pointer lives in the main window's space; a sheet's point is offset by where the sheet sits.
            await movePointer(to: CGPoint(x: found.center.x + win.frame.minX - main.frame.minX,
                                          y: found.center.y + win.frame.minY - main.frame.minY))
            if step.op == "press" {
                await click(at: found.center, in: win, what: found.name)
            } else {
                // A layout that was still settling (after a scroll) can move the control: settle on it again.
                if let again = await HarnessCapture.locate(text: step.name ?? "", role: step.value, in: win, patience: 0),
                   hypot(again.center.x - found.center.x, again.center.y - found.center.y) > 2 {
                    await movePointer(to: CGPoint(x: again.center.x + win.frame.minX - main.frame.minX,
                                                  y: again.center.y + win.frame.minY - main.frame.minY))
                }
                say("moved to \(found.name)")
                await settle(0.3)
            }
        case "scroll":
            let main = try requireWindow()
            let win = main.attachedSheet ?? main
            guard let found = await HarnessCapture.locate(text: step.name ?? "", role: step.value, in: win) else {
                throw HarnessError(message: "no control matching \"\(step.name ?? "")\" could be found" + Self.lookupHint)
            }
            // Scroll the scroll view that lies at the control's x and the window's middle, by the control's distance from the middle.
            let middle = CGPoint(x: found.center.x, y: win.frame.height * 0.5)
            let offset = middle.y - found.center.y
            let steps = recorder.map { Int(0.4 * $0.fps) } ?? 1
            guard await HarnessCapture.scroll(window: win, at: middle, by: offset, steps: max(steps, 1), settle: { await self.settle($0) }) else {
                throw HarnessError(message: "no scroll view under \(found.name)")
            }
            say("scrolled \(found.name) into view")
            await settle(0.5)
        case "pointer":
            let main = try requireWindow()
            let s = step.size ?? [0, 0]
            let inSheet = step.value?.hasPrefix("sheet") == true
            guard let target = inSheet ? main.attachedSheet : main else { throw HarnessError(message: "pointer: no sheet is open") }
            // Window coordinates (origin bottom left) of the point given from the target's top left; a
            // negative y counts up from the bottom edge (a sheet grows downward as its text changes).
            let point = CGPoint(x: s[0] < 0 ? target.frame.width + s[0] : s[0], y: s[1] < 0 ? -s[1] : target.frame.height - s[1])
            await movePointer(to: CGPoint(x: point.x + target.frame.minX - main.frame.minX, y: point.y + target.frame.minY - main.frame.minY))
            if step.value == "click" || step.value == "sheetClick" {
                await click(at: point, in: target, what: "\(Int(s[0])),\(Int(s[1]))\(inSheet ? " in the sheet" : "")")
            } else {
                await settle(0.3)
            }
        case "wait":
            await settle(step.seconds ?? 0.5)
        case "capture":
            await remindKey()
            try await write(window: try requireWindow(), stem: step.name ?? "capture")
        case "still":
            await remindKey()
            let stem = HarnessScenario.fileStem(step.name ?? "still")
            guard let rep = currentFrame(), let png = rep.representation(using: .png, properties: [:]) else {
                throw HarnessError(message: "could not compose a frame")
            }
            try png.write(to: outDir.appendingPathComponent(stem + ".png"))
            say("wrote \(stem).png")
        case "captureSheet":
            guard let sheet = try requireWindow().attachedSheet else { throw HarnessError(message: "no sheet is open") }
            try await write(window: sheet, stem: step.name ?? "sheet")
        case "menus":
            let stem = HarnessScenario.fileStem(step.name ?? "menus")
            try HarnessCapture.menuDump().write(to: outDir.appendingPathComponent(stem + ".menus.txt"), atomically: true, encoding: .utf8)
            say("wrote \(stem).menus.txt")
        case "record":
            guard recorder == nil else { throw HarnessError(message: "a recording is already running; endRecord it first") }
            let r = try HarnessRecorder(name: HarnessScenario.fileStem(step.name ?? "clip"), outDir: outDir, fps: step.fps ?? 10)
            r.frameProvider = { [weak self] in self?.currentFrame() }
            recorder = r
            r.start()
            say("recording \(r.name) at \(Int(r.fps)) fps")
        case "endRecord":
            guard let r = recorder else { throw HarnessError(message: "no recording is running") }
            let s = await r.stop()
            recorder = nil
            say("wrote \(r.name).ffconcat (\(s.count) frames, \(String(format: "%.1f", s.seconds)) s, "
                + "\(Int(r.captureSeconds / Double(max(s.count, 1)) * 1000)) ms per frame)")
        case "caption":
            caption = step.value
            await settle(0.2)
        case "simulate":
            guard let model = SimulationPreviewModel.harnessCurrent, doc.centerMode != .design2D else {
                throw HarnessError(message: "no 3D preview is shown (use mode 3d or split, then wait, first)")
            }
            try await waitUntil("the simulation to load", timeout: 40) { model.totalTime > 0 && !model.isBusy }
            if let fraction = step.value.flatMap(Double.init) {
                model.pause()
                model.time = model.totalTime * min(max(fraction, 0), 1)
                try await waitUntil("the simulation frame", timeout: 20) { !model.isBusy }
                await settle(0.8)
                break
            }
            let seconds = step.seconds ?? 6
            let fps = recorder?.fps ?? 10
            let n = max(1, Int(seconds * fps))
            model.pause()
            for i in 0...n {
                model.time = model.totalTime * Double(i) / Double(n)
                await settle(1 / fps)
            }
            await settle(0.5)
        case "view":
            guard let model = SimulationPreviewModel.harnessCurrent, let dir = PreviewViewDirection(rawValue: step.value ?? "") else {
                throw HarnessError(message: "no 3D preview is shown (use mode 3d or split, then wait, first)")
            }
            model.stockScene.setView(dir)
            await settle(0.8)
        default:
            throw HarnessError(message: "unhandled op \(step.op)")
        }
    }

    private static var lookupHint: String {
        if screenIsLocked { return " (the screen is locked: unlock it, control lookups need a visible window)" }
        if !AXIsProcessTrusted() { return " (Accessibility must be granted to your terminal)" }
        return " (check the name in a capture's .ax.txt; a covered or dark window is also invisible to lookups)"
    }

    private func sheet(named name: String) throws -> DocumentSheet {
        switch name {
        case "jobSetup": return .jobSetup
        case "exportGCode": return .exportGCode(.all)
        case "saveAllToolpaths": return .saveAllToolpaths
        case "validation": return .validation
        case "keepOutZones": return .keepOutZones
        case "nesting": return .nesting
        case "fixtures": return .fixtures
        case "tiling": return .tiling
        case "partLabels": return .partLabels
        case "variables": return .variables
        case "productionPlates": return .productionPlates
        case "offset": return .offset
        case "joinVectors": return .drawing(.joinVectors)
        case "inlayWizard": return .inlayWizard
        default: throw HarnessError(message: "unknown sheet \"\(name)\"")
        }
    }

    private func write(window: NSWindow, stem rawStem: String) async throws {
        let stem = HarnessScenario.fileStem(rawStem)
        guard let png = HarnessCapture.png(of: window) else { throw HarnessError(message: "could not capture the window") }
        try png.write(to: outDir.appendingPathComponent(stem + ".png"))
        try (await HarnessCapture.accessibilityTree(of: window) + HarnessCapture.scrollViewNotes(of: window))
            .write(to: outDir.appendingPathComponent(stem + ".ax.txt"), atomically: true, encoding: .utf8)
        say("wrote \(stem).png (\(Int(window.frame.width))x\(Int(window.frame.height)) pt) and \(stem).ax.txt")
    }

    // MARK: Input

    /// Virtual key codes (US layout) for typed characters; the field editor wants the code and the text to agree.
    private static let keyCodes: [Character: UInt16] = {
        var m: [Character: UInt16] = [:]
        for (i, c) in "asdfhgzxcv".enumerated() { m[c] = UInt16(i) }
        for (c, k) in zip("bqweryt123465=97-80]ou[ip", [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35] as [UInt16]) { m[c] = k }
        for (c, k) in zip("l;'k,/nm.", [37, 41, 39, 40, 43, 44, 45, 46, 47] as [UInt16]) { m[c] = k }
        m[" "] = 49; m["\t"] = 48; m["\r"] = 36; m["\n"] = 36
        return m
    }()

    private func send(characters: String, keyCode: UInt16, command: Bool = false, to target: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: command ? [.command] : [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: target.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false,
                                               keyCode: keyCode) else { continue }
            if command { NSApp.sendEvent(event) } else { target.sendEvent(event) }
        }
    }

    /// Clicks at `point` in `win`, showing the click ring in a recording.
    private func click(at point: CGPoint, in win: NSWindow, what: String) async {
        if wantsKey, !win.isKeyWindow, NSApp.isActive { await makeKey(win) }
        pressed = true
        say("clicking \(what) at \(Int(point.x)),\(Int(win.frame.height - point.y))")
        await HarnessCapture.click(at: point, in: win)
        say("pressed \(what)")
        await settle(recorder == nil ? 0.05 : 0.25)
        pressed = false
        await settle(0.6)
    }

    /// In a recording, glides the pointer onto the control named `text` and flashes the click ring, so a
    /// programmatic selection looks like the click it stands for. Nothing is sent to the control.
    private func pointAndFlash(at text: String, role: String?) async {
        guard recorder != nil, let main = window,
              let found = await HarnessCapture.locate(text: text, role: role, in: main, patience: 1) else { return }
        await movePointer(to: found.center)
        pressed = true
        await settle(0.25)
        pressed = false
    }

    /// Moves the synthetic pointer to `target` (main-window points, origin bottom left): in a recording it
    /// glides there over half a second, otherwise it jumps.
    private func movePointer(to target: CGPoint) async {
        guard let r = recorder, let w = window else { pointer = target; return }
        let from = pointer ?? CGPoint(x: w.frame.width * 0.6, y: 30)
        let steps = max(1, Int(0.5 * r.fps))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            pointer = CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased)
            await settle(1 / r.fps)
        }
        pointer = target
    }

    private func currentFrame() -> NSBitmapImageRep? {
        guard let w = window else { return nil }
        return HarnessCapture.frame(of: w, overlay: .init(pointer: pointer, pressed: pressed, caption: caption))
    }

    // MARK: Waiting

    /// Lets SwiftUI lay out and the run loop drain.
    private func settle(_ seconds: Double = 0.45) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitUntil(_ what: String, timeout: Double = 15, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw HarnessError(message: "timed out waiting for \(what)") }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
#endif
