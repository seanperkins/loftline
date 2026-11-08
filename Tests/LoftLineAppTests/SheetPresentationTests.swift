import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The document's one sheet slot and its alert (docs/implicit-state-machines.md #14): a command never replaces an open
/// sheet (whose draft would be lost), and a report never replaces an alert that is showing.
@Suite @MainActor struct SheetPresentationTests {
    func doc() -> LoftLineDocument { LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library()) }

    @Test func aMenuCommandDoesNotReplaceAnOpenSheet() {
        let d = doc()
        d.sheet = .jobSetup
        d.sheet = .postProcessors
        #expect(d.sheet == .jobSetup)
        d.sheet = nil        // dismissed
        d.sheet = .postProcessors
        #expect(d.sheet == .postProcessors)
    }

    @Test func queuedSheetsStillOpen() {
        // A sheet's own button that opens another (Save All's Check Toolpaths) swaps it on purpose.
        let d = doc()
        d.sheet = .saveAllToolpaths
        d.replaceSheet(.validation)
        #expect(d.sheet == .validation)
    }

    @Test func secondAlertWaits() async throws {
        let d = doc()
        d.report(AlertMessage(title: "A", message: "first"))
        d.report(AlertMessage(title: "B", message: "second"))
        #expect(d.alert?.title == "A")
        d.alert = nil        // dismissed
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(d.alert?.title == "B")
    }

    @Test func anAlertReportedBeforeTheDeferredOneIsNotReplaced() async throws {
        let d = doc()
        d.report(AlertMessage(title: "A", message: "first"))
        d.report(AlertMessage(title: "B", message: "second"))
        d.alert = nil        // dismissed; B is shown on the next turn of the run loop
        d.report(AlertMessage(title: "C", message: "third"))
        #expect(d.alert?.title == "C")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(d.alert?.title == "C")
        d.alert = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(d.alert?.title == "B")
    }

    @Test func closingASheetDoesNotReplaceAnAlertThatIsShowing() {
        // An alert shows, a sheet opens over it, something in the sheet reports: closing the sheet keeps the first
        // alert, and the held one waits for it.
        let d = doc()
        d.report(AlertMessage(title: "A", message: "first"))
        d.sheet = .jobSetup
        d.report(AlertMessage(title: "B", message: "second"))
        d.sheet = nil
        d.sheetDismissed()
        #expect(d.alert?.title == "A")
    }
}
