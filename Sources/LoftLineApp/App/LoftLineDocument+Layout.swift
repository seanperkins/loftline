import AppKit
import CADCore
import CAMCore
import Foundation
import UniformTypeIdentifiers
import LoftLineKit

/// Layout commands (job sheet, sheets) kept out of LoftLineDocument.swift.
extension LoftLineDocument {
    /// File > Export Job Sheet…: recalculates stale toolpaths, writes a printable HTML setup
    /// sheet and opens it in the default browser.
    @MainActor
    func exportJobSheet() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (document.name.isEmpty ? "Untitled" : document.name) + " job sheet.html"
        panel.message = "Save a printable operator sheet (origin, tools and toolpath order)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            // The sheet lists what the program cuts, so it prints only fresh results (as the export sheets post them).
            let targets = project.operations.filter(\.setup.isEnabled).map(\.id)
            guard await calculateUntilFresh(targets: targets) else {
                report(AlertMessage(title: "Job sheet not saved",
                                    message: "The project changed while it was being calculated. Export the job sheet again."))
                return
            }
            let html = JobSheetHTML.render(makeJobSheet(settings: TimeEstimateStore.shared.settings))
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(url)
            } catch {
                report(AlertMessage(title: "Job sheet not saved", message: error.localizedDescription))
            }
        }
    }

    /// `settings`: the time-estimate settings for the total; the export command passes the live
    /// store's, which the sidebar shows.
    func makeJobSheet(settings: TimeEstimateSettings, date: Date = Date()) -> JobSheet {
        var sheet = JobSheet.make(project: outputProject, results: results, profile: postProfile,
                                  groupByTool: UserDefaults.standard.bool(forKey: GCodeExporter.groupByToolKey),
                                  rapidRate: rapidRateInDocumentUnits, date: date, sheets: JobSheet.sheets(of: project),
                                  settings: settings)
        // Multi-sheet and two-sided jobs (io): say which material sheet and side this sheet is for.
        sheet.jobName = document.name + (document.isMultiSheet ? " – \(document.currentSheetName)" : "")
            + (isTwoSided ? " (\(activeSide.displayName) side)" : "")
        return sheet
    }

    /// Design > Layout > Sheet on Material: swaps which nesting sheet is machined.
    func showSheetOnMaterial(_ n: Int) {
        perform("Sheet \(n) on Material") { NestSheets.activate(n, in: &$0.document) }
        requestCanvas(.fit)
    }
}
