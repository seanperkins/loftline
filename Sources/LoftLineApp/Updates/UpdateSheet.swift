import AppKit
import Combine
import SwiftUI

/// The update window's content for one `UpdatePresentation`; knows nothing about the controller.
struct UpdateSheetContent: View {
    let presentation: UpdatePresentation
    let perform: (UpdatePresentation.Choice) -> Void

    private static let skipping: [UpdatePresentation.Choice] = [.skipThisVersion, .later]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(presentation.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if presentation.showsProgress {
                ProgressView().controlSize(.small).accessibilityLabel(presentation.title)
            }
            if let warning = presentation.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }
            if let notes = presentation.notes {
                Text("What's new").font(.headline)
                // Plain text: release notes come from the feed and are never interpreted as markup or links.
                ScrollView {
                    Text(verbatim: notes).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 140)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            if !presentation.choices.isEmpty {
                HStack {
                    ForEach(presentation.choices.filter { Self.skipping.contains($0) }, id: \.self) { button($0) }
                    Spacer()
                    ForEach(presentation.choices.filter { !Self.skipping.contains($0) }, id: \.self) { button($0) }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func button(_ choice: UpdatePresentation.Choice) -> some View {
        if choice == presentation.defaultChoice {
            Button(choice.title) { perform(choice) }.keyboardShortcut(.defaultAction)
        } else {
            Button(choice.title) { perform(choice) }
        }
    }
}

/// The update window: the controller's state, and what each button does with it.
struct UpdateSheet: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        UpdateSheetContent(presentation: .make(for: controller.state, currentVersion: controller.currentVersion),
                           perform: perform)
    }

    private func perform(_ choice: UpdatePresentation.Choice) {
        switch choice {
        case .installAndRestart:
            Task { await install(relaunch: true) }
        case .installWhenIQuit:
            Task { await install(relaunch: false) }
        case .skipThisVersion:
            controller.skipVersion()
            UpdateWindow.close()
        case .later, .ok:
            UpdateWindow.close()
        }
    }

    /// Downloads and verifies first when that has not happened yet; only a verified archive can be installed.
    private func install(relaunch: Bool) async {
        if case .available = controller.state { await controller.download() }
        guard case .readyToInstall = controller.state else { return }
        if relaunch {
            controller.installNow()
        } else {
            controller.installOnQuit()
            if case .installPending = controller.state { UpdateWindow.close() }
        }
    }
}

/// The window, its menu entry point, and what happens after launch.
@MainActor
enum UpdateWindow {
    static let id = "loftline-update"

    static func show() {
        HostedWindows.show(id: id, title: "Software Update", size: CGSize(width: 520, height: 360), resizable: false) {
            UpdateSheet(controller: .shared)
        }
    }

    static func close() { HostedWindows.close(id: id) }

    /// LoftLine ▸ Check for Updates…: open the window, then look.
    static func checkByHand() {
        show()
        Task { await UpdateController.shared.checkNow(userInitiated: true) }
    }
}

/// Started once the app has launched.
@MainActor
enum UpdateLaunch {
    private static var observer: AnyCancellable?
    private static var timer: Timer?

    /// - A found update opens the window once per version.
    /// - Leftovers of an interrupted update are removed a while after launch, so a missing app can still be recovered
    ///   until the new one has proved itself.
    /// - A background check shortly after launch, then daily (the controller itself refuses to ask more than once a day, and
    ///   only a release build with the preference on asks at all).
    static func start() {
        let updates = UpdateController.shared
        observer = updates.$state.sink { state in
            if case .available(let entry) = state, updates.shouldPrompt(for: entry) {
                updates.markPrompted(entry)
                UpdateWindow.show()
            }
        }
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { UpdateCleanup.removeOldBundles(besides: app) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { Task { await updates.checkNow(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await updates.checkNow(userInitiated: false) }
        }
    }
}
