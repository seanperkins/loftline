import Foundation
import UpdateCore

/// What the update window says and offers for each controller state. Pure data: every state is tested without a window.
struct UpdatePresentation: Equatable {
    enum Choice: Hashable {
        case installAndRestart, installWhenIQuit, skipThisVersion, later, ok

        var title: String {
            switch self {
            case .installAndRestart: return "Install and Restart"
            case .installWhenIQuit: return "Install when I quit"
            case .skipThisVersion: return "Skip this version"
            case .later: return "Later"
            case .ok: return "OK"
            }
        }
    }

    var title: String
    var detail: String
    /// The release notes, shown as plain text.
    var notes: String?
    var warning: String?
    var showsProgress = false
    var choices: [Choice]
    var defaultChoice: Choice?

    static let gcodeWarning = "The post output changed in this release. Export your G-code again and check it before you cut."

    static func make(for state: UpdateController.State, currentVersion: String) -> UpdatePresentation {
        switch state {
        case .idle:
            return UpdatePresentation(title: "Software Update", detail: "LoftLine is version \(currentVersion).", choices: [.ok],
                                      defaultChoice: .ok)
        case .checking:
            return UpdatePresentation(title: "Checking for updates…", detail: "Asking github.com for the latest release.",
                                      showsProgress: true, choices: [])
        case .upToDate:
            return UpdatePresentation(title: "LoftLine is up to date", detail: "You have version \(currentVersion), the latest.",
                                      choices: [.ok], defaultChoice: .ok)
        case .available(let entry), .readyToInstall(let entry):
            return UpdatePresentation(
                title: "LoftLine \(entry.version) is available", detail: "You have version \(currentVersion).",
                notes: entry.notes.isEmpty ? nil : entry.notes, warning: entry.gcodeChanged ? gcodeWarning : nil,
                choices: [.installAndRestart, .installWhenIQuit, .skipThisVersion, .later], defaultChoice: .installWhenIQuit)
        case .downloading:
            return UpdatePresentation(title: "Downloading the update…", detail: "It is checked against its signature before anything is installed.",
                                      showsProgress: true, choices: [])
        case .installPending(let relaunch):
            return UpdatePresentation(
                title: relaunch ? "Restarting to install the update" : "The update installs when you quit",
                detail: relaunch
                    ? "LoftLine is quitting and will reopen on the new version. If you cancelled the quit, the update installs the next time LoftLine quits."
                    : "Nothing changes until you quit LoftLine. It will not reopen by itself.",
                choices: [.ok], defaultChoice: .ok)
        case .failed(let message):
            return UpdatePresentation(title: "The update did not finish", detail: message, choices: [.ok], defaultChoice: .ok)
        }
    }
}
