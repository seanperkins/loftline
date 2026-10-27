import AppKit
import Foundation
import SwiftUI
import Testing
import UpdateCore
@testable import LoftLineApp

/// The update window is a pure function of the controller's state (`UpdatePresentation`), so every state is checked without
/// a window; one hosting pass per state catches layout crashes.
@Suite struct UpdateUITests {
    static func entry(version: String = "0.2.1", gcodeChanged: Bool = false, notes: String = "Fixes and improvements.") -> UpdateEntry {
        UpdateEntry(version: version, url: URL(string: UpdateManifest.urlPrefix + "v\(version)/LoftLine-v\(version)-macos-arm64.zip")!,
                    sha256: String(repeating: "a", count: 64), signature: Data(repeating: 1, count: 512),
                    gcodeChanged: gcodeChanged, notes: notes)
    }

    static var everyState: [UpdateController.State] {
        [.idle, .checking, .upToDate, .available(entry()), .available(entry(gcodeChanged: true)), .available(entry(notes: "")),
         .available(entry(notes: String(repeating: "A long line of release notes. ", count: 200))), .downloading,
         .readyToInstall(entry()), .installPending(relaunch: true), .installPending(relaunch: false),
         .failed("LoftLine could not reach the update server.")]
    }

    static let fourChoices: [UpdatePresentation.Choice] = [.installAndRestart, .installWhenIQuit, .skipThisVersion, .later]

    @Test @MainActor func sheetRendersEveryState() {
        for state in Self.everyState {
            let presentation = UpdatePresentation.make(for: state, currentVersion: "0.2.0")
            let host = NSHostingView(rootView: UpdateSheetContent(presentation: presentation, perform: { _ in }))
            let size = host.fittingSize
            #expect(size.width > 100 && size.height > 40, "\(state): \(size)")
            #expect(!presentation.title.isEmpty, "\(state)")
        }
    }

    @Test func sheetWarnsWhenGcodeChanged() {
        let changed = UpdatePresentation.make(for: .available(Self.entry(gcodeChanged: true)), currentVersion: "0.2.0")
        #expect(changed.warning?.contains("post output changed") == true, "\(changed.warning ?? "nil")")
        let same = UpdatePresentation.make(for: .available(Self.entry(gcodeChanged: false)), currentVersion: "0.2.0")
        #expect(same.warning == nil)
        let ready = UpdatePresentation.make(for: .readyToInstall(Self.entry(gcodeChanged: true)), currentVersion: "0.2.0")
        #expect(ready.warning?.contains("post output changed") == true, "the warning stays once it is downloaded")
    }

    @Test func sheetOffersTheFourChoices() {
        for state in [UpdateController.State.available(Self.entry()), .readyToInstall(Self.entry())] {
            let presentation = UpdatePresentation.make(for: state, currentVersion: "0.2.0")
            #expect(presentation.choices == Self.fourChoices, "\(state)")
        }
        #expect(Self.fourChoices.map(\.title) == ["Install and Restart", "Install when I quit", "Skip this version", "Later"])
    }

    @Test func installWhenIQuitIsTheDefaultChoice() {
        let presentation = UpdatePresentation.make(for: .available(Self.entry()), currentVersion: "0.2.0")
        #expect(presentation.defaultChoice == .installWhenIQuit)
    }

    @Test func everyOtherStateOffersNothingToInstall() {
        for state in Self.everyState {
            if case .available = state { continue }
            if case .readyToInstall = state { continue }
            let presentation = UpdatePresentation.make(for: state, currentVersion: "0.2.0")
            #expect(!presentation.choices.contains(.installAndRestart) && !presentation.choices.contains(.installWhenIQuit), "\(state)")
        }
    }

    @Test func availableShowsTheVersionsAndTheNotes() {
        let presentation = UpdatePresentation.make(for: .available(Self.entry(version: "0.2.1", notes: "Faster previews.")), currentVersion: "0.2.0")
        #expect(presentation.title.contains("0.2.1"))
        #expect(presentation.detail.contains("0.2.0"))
        #expect(presentation.notes == "Faster previews.")
        #expect(UpdatePresentation.make(for: .available(Self.entry(notes: "")), currentVersion: "0.2.0").notes == nil, "empty notes show nothing")
    }

    @Test func progressShowsWhileCheckingAndDownloadingOnly() {
        for state in Self.everyState {
            let shows = UpdatePresentation.make(for: state, currentVersion: "0.2.0").showsProgress
            switch state {
            case .checking, .downloading: #expect(shows, "\(state)")
            default: #expect(!shows, "\(state)")
            }
        }
    }

    @Test func theBannerShowsOnlyWhenThereIsAnUpdateToActOn() {
        for state in Self.everyState {
            let expected: Bool
            switch state {
            case .available, .readyToInstall, .installPending: expected = true
            default: expected = false
            }
            #expect(state.offersAttention == expected, "\(state)")
        }
    }

    @Test @MainActor func theBannerAndTheWindowHostWithoutCrashing() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let banner = NSHostingView(rootView: UpdateBanner(controller: rig.controller))
        #expect(banner.fittingSize.width >= 0)
        let sheet = NSHostingView(rootView: UpdateSheet(controller: rig.controller))
        #expect(sheet.fittingSize.width > 100)
    }

    @Test func preferencesHelpExplainsUpdateChecks() {
        let body = HelpTopic.preferences.body
        #expect(body.contains("github.com"))
        #expect(body.localizedCaseInsensitiveContains("check for updates automatically"))
        #expect(body.localizedCaseInsensitiveContains("no identifiers") || body.localizedCaseInsensitiveContains("nothing else"))
    }
}
