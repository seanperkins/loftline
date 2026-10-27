import AppKit
import SwiftUI

final class LoftLineAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Scripted UI run (see UIHarness): no Welcome window, no recovery prompt or timer, no Dock icon.
        if UIHarness.isActive {
            NSApp.setActivationPolicy(UIHarness.request?.active == true ? .regular : .accessory)
            UIHarness.shared.start()
            return
        }
        #endif
        // Needed when launched as a bare SwiftPM executable (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        RecoveryCoordinator.shared.start()
        // Let the first windows open before showing the Welcome window and asking about work
        // left by a crash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if PreferencesModel.shared.prefs.showWelcomeAtLaunch { WelcomeView.show() }
            RecoveryPrompt.offer(interactive: false)
        }
        UpdateLaunch.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecoveryCoordinator.shared.cleanUpOnQuit()
        // The one place the update helper starts: the quit can no longer be cancelled.
        MainActor.assumeIsolated { UpdateController.shared.applicationWillTerminate() }
    }
}

/// Started from main.swift, after it has checked that the command line was not asked for.
struct LoftLineApp: App {
    @NSApplicationDelegateAdaptor(LoftLineAppDelegate.self) private var appDelegate
    @StateObject private var toolLibrary = ToolLibraryModel.shared

    var body: some Scene {
        DocumentGroup(newDocument: { LoftLineDocument() }) { file in
            ContentView(document: file.document)
                .environmentObject(toolLibrary)
                .frame(minWidth: 1000, minHeight: 640)
        }
        // Open wider than the minimum so the 2D | 3D split has room beside the sidebar and inspector.
        .defaultSize(width: 1280, height: 820)
        .commands {
            LoftLineCommands()
            VectorMenuCommands()
            GadgetCommands()
        }

        Window("Tool Database", id: ToolDatabaseView.windowID) {
            ToolDatabaseView()
                .environmentObject(toolLibrary)
        }
        .defaultSize(width: 820, height: 600)

        Settings {
            PreferencesView()
        }
    }
}
