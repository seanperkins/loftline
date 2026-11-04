import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// SwiftUI drops an alert set while a sheet is up, so every message for the user goes through `LoftLineDocument.report`,
/// which shows it at once or after the sheet closes (issue #64; the pattern of issue #22).
@MainActor
@Suite struct ReportRoutingTests {
    func document() -> LoftLineDocument {
        LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
    }

    @Test func distortWithNothingSelectedWaitsForTheDialogItClosed() {
        let doc = document()
        doc.setSelection([])
        doc.sheet = .drawing(.distort)
        doc.beginEnvelopeEdit()                       // the Drag Corners button runs this before it closes the sheet
        #expect(doc.alert == nil && doc.deferredAlert?.title == "Distort")
        doc.sheet = nil
        doc.sheetDismissed()
        #expect(doc.alert?.title == "Distort")
    }

    @Test func aGadgetsOutputWaitsForTheAppKitDialogItRanFrom() throws {
        let doc = document()
        let script = GadgetScript.parse(source: "loftline.log('hello from the gadget');", fallbackName: "Talk", origin: .builtIn).script
        doc.platformSheetOpen = true                  // the gadget run dialog is attached by AppKit
        _ = doc.runGadget(script, values: [:])
        #expect(doc.alert == nil)
        #expect(doc.deferredAlert?.message.contains("hello from the gadget") == true)
        doc.platformSheetOpen = false                 // the dialog's close
        doc.sheetDismissed()
        #expect(doc.alert?.message.contains("hello from the gadget") == true)
    }

    /// Closing one of two sheets leaves a held report waiting for the other (the gadget dialog opened from a menu while a
    /// SwiftUI sheet is up, and the reverse).
    @Test func aHeldReportWaitsUntilNoSheetOfEitherKindIsUp() throws {
        let doc = document()
        let script = GadgetScript.parse(source: "loftline.log('both');", fallbackName: "Talk", origin: .builtIn).script
        doc.sheet = .jobSetup
        doc.platformSheetOpen = true
        _ = doc.runGadget(script, values: [:])
        #expect(doc.alert == nil && doc.deferredAlert != nil)
        doc.platformSheetOpen = false                  // the gadget dialog closes, the SwiftUI sheet is still up
        doc.sheetDismissed()
        #expect(doc.alert == nil && doc.deferredAlert != nil)
        doc.sheet = nil                                // now the last sheet closes
        doc.sheetDismissed()
        #expect(doc.alert?.message.contains("both") == true && doc.deferredAlert == nil)

        let other = document()                          // and the other order
        other.sheet = .jobSetup
        other.platformSheetOpen = true
        _ = other.runGadget(script, values: [:])
        other.sheet = nil                               // the SwiftUI sheet closes first
        other.sheetDismissed()
        #expect(other.alert == nil && other.deferredAlert != nil)
        other.platformSheetOpen = false
        other.sheetDismissed()
        #expect(other.alert?.message.contains("both") == true)
    }

    @Test func aMessageWithNoSheetUpShowsAtOnce() {
        let doc = document()
        doc.report(AlertMessage(title: "Plain", message: "now"))
        #expect(doc.alert?.title == "Plain" && doc.deferredAlert == nil)
    }

    /// The rule is the point, so it is checked where it can be broken: no source file sets `alert` itself (the harness
    /// clearing it, and `report` / `sheetDismissed` in LoftLineDocument, are the only writers).
    @Test func noCodeSetsAnAlertDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LoftLineApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("alert = AlertMessage(") || line.contains("alert = message") && !line.contains("sheet == nil") {
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "set an alert directly (use report): \(offenders)"))
    }
}
