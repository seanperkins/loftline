import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import LoftLineKit

/// Multi-sheet jobs: switching, adding and deleting material sheets.
extension LoftLineDocument {
    /// Makes another sheet current (one undo step). Its job setup moves into `document.job`, so
    /// the canvas, Job Setup and output all follow it.
    func switchSheet(_ id: UUID) {
        guard id != document.currentSheetID else { return }
        clearSelection()
        tabEditingOperationID = nil
        perform("Switch Sheet") { p in
            p.document.switchToSheet(id)
            p.ensureSheetLayer()
            p.ensureBottomLayer()
        }
        activeSide = .top
        requestCanvas(.fit)
    }

    /// Adds a sheet with the current material setup and switches to it.
    func addSheet() {
        let n = document.allSheets.count + 1
        var newID: UUID?
        perform("Add Sheet") { p in
            newID = p.document.addSheet(name: "Sheet \(n)", job: p.document.job, layerName: "Sheet \(n)",
                                        colorHex: "#1E90FF")
        }
        if let id = newID { switchSheet(id) }
    }

    /// Deletes the current sheet with its layers, vectors and their toolpath selections.
    func deleteCurrentSheet() {
        guard document.isMultiSheet,
              let other = document.allSheets.first(where: { $0.id != document.currentSheetID }) else { return }
        let doomed = document.currentSheetID
        let alert = NSAlert()
        alert.messageText = "Delete \"\(document.currentSheetName)\"?"
        alert.informativeText = "Its layers and vectors are deleted too. You can undo this."
        // Cancel is the default (Return); the destructive choice has to be clicked.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        PanelRunner.present(alert) { [self] response in
            guard response == .alertSecondButtonReturn else { return }
            clearSelection()
            perform("Delete Sheet") { p in
                p.document.switchToSheet(other.id)
                let removed = p.document.removeSheet(doomed)
                p.deleteShapes(removed)
                p.ensureSheetLayer()
            }
            activeSide = .top
            requestCanvas(.fit)
        }
    }
}


extension LoftLineProject {
    /// The current sheet always has at least one layer to draw on.
    mutating func ensureSheetLayer() {
        let current = document.currentSheetID
        guard !document.layers.contains(where: { ($0.sheetID ?? MaterialSheet.primaryID) == current }) else { return }
        let id = addLayer(named: document.currentSheetName)
        if let i = document.layers.firstIndex(where: { $0.id == id }) { document.layers[i].sheetID = document.activeSheetID }
    }
}

/// Design → Sheets submenu.
struct SheetsMenu: View {
    var document: LoftLineDocument?

    var body: some View {
        Menu("Sheets") {
            if let doc = document {
                ForEach(doc.document.allSheets) { s in
                    Toggle(s.name + "  (\(GCodeExporter.materialDescription(sheetDoc(doc.document, s))))",
                           isOn: Binding(get: { s.id == doc.document.currentSheetID }, set: { _ in doc.switchSheet(s.id) }))
                }
                Divider()
            }
            Button("Add Sheet") { document?.addSheet() }
            Button("Delete Current Sheet…") { document?.deleteCurrentSheet() }
                .disabled(!(document?.document.isMultiSheet ?? false))
        }
        .disabled(document == nil)
    }

    private func sheetDoc(_ d: Document, _ s: MaterialSheet) -> Document {
        var x = d
        x.job = s.job
        return x
    }
}
