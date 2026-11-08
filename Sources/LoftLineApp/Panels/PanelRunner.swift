import AppKit
import UniformTypeIdentifiers
import LoftLineKit

/// Shows file panels and alerts as sheets on the frontmost window (the document window, or the sheet
/// on it) instead of app-modal windows floating over everything. The HIG asks document-based apps for
/// document-modal panels; the caller continues in `completion`, so nothing blocks the run loop.
enum PanelRunner {
    private static var host: NSWindow? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        return window?.isVisible == true ? window : nil
    }

    /// A save panel; under the UI harness (debug builds) one that answers with the scenario's file target.
    static func makeSavePanel() -> NSSavePanel {
        #if DEBUG
        if let url = harnessTarget { return HarnessSavePanel(answering: url) }
        #endif
        return NSSavePanel()
    }

    /// An open panel (for choosing a folder); see `makeSavePanel`.
    static func makeOpenPanel() -> NSOpenPanel {
        #if DEBUG
        if let url = harnessTarget { return HarnessOpenPanel(answering: url) }
        #endif
        return NSOpenPanel()
    }

    #if DEBUG
    /// The UI harness cannot drive the system file panel. A scenario's `fileTarget` step sets this, and
    /// every save or folder panel made by `makeSavePanel`/`makeOpenPanel` answers OK with it at once
    /// (until `closeSheet` or an empty `fileTarget` clears it), so the sheet's real save (and failure)
    /// path runs.
    nonisolated(unsafe) static var harnessTarget: URL?
    #endif

    static func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        #if DEBUG
        if panel is HarnessSavePanel || panel is HarnessOpenPanel { completion(.OK); return }
        #endif
        if let host {
            panel.beginSheetModal(for: host, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let host {
            alert.beginSheetModal(for: host, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// A "Format" pop-up for the Export Vectors panel, so the format is chosen from a list instead of by
/// typing an extension. Keep a reference until the panel closes.
final class VectorFormatAccessory: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, fileName: String) {
        self.panel = panel
        super.init()
        for format in VectorExportFormat.allCases { popup.addItem(withTitle: format.title) }
        popup.target = self
        popup.action = #selector(formatChanged)
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        panel.accessoryView = row
        panel.nameFieldStringValue = fileName
        apply(VectorExportFormat(fileName: fileName) ?? .svg)
    }

    private var selected: VectorExportFormat { VectorExportFormat.allCases[popup.indexOfSelectedItem] }

    @objc private func formatChanged() { apply(selected) }

    private func apply(_ format: VectorExportFormat) {
        guard let panel else { return }
        popup.selectItem(at: VectorExportFormat.allCases.firstIndex(of: format) ?? 0)
        panel.allowedContentTypes = UTType(filenameExtension: format.fileExtension).map { [$0] } ?? []
        panel.nameFieldStringValue = format.fileName(from: panel.nameFieldStringValue)
    }
}

/// The name a save panel is given. A panel that allows one file type adds that type's extension
/// itself, so a suggested name that already ends in it showed up as "Untitled.tap.tap".
enum SavePanelName {
    static func suggested(_ fileName: String, allowedExtension: String) -> String {
        let name = fileName as NSString
        return name.pathExtension.lowercased() == allowedExtension.lowercased() ? name.deletingPathExtension : fileName
    }
}

#if DEBUG
/// Answers OK with a fixed URL instead of opening (see `PanelRunner.harnessTarget`).
final class HarnessSavePanel: NSSavePanel {
    private let target: URL
    init(answering url: URL) { target = url; super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true) }
    override var url: URL? { target }
}

final class HarnessOpenPanel: NSOpenPanel {
    private let target: URL
    init(answering url: URL) { target = url; super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true) }
    override var url: URL? { target }
}
#endif
