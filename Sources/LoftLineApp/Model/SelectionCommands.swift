import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import LoftLineKit

/// Edit ▸ Select helpers. Candidates are the editable shapes on the shown side/sheet (the same
/// set Select All uses); a command that finds nothing beeps and keeps the selection.
extension LoftLineDocument {
    var selectableShapes: [Shape] {
        project.document.shapes.filter { project.isEditable($0) && isOnActiveSide($0) }
    }

    /// Replaces the selection; false (and a beep) when `ids` is empty.
    @discardableResult
    private func selectFound(_ ids: [UUID]) -> Bool {
        guard !ids.isEmpty else { NSSound.beep(); return false }
        setSelection(ids)
        return true
    }

    @discardableResult func selectOpenVectors() -> Bool { selectFound(SelectionQueries.openVectors(selectableShapes)) }

    /// The extra copies of vectors drawn on top of each other (first copy left unselected).
    @discardableResult func selectDuplicateVectors() -> Bool {
        selectFound(SelectionQueries.duplicates(selectableShapes, tolerance: VectorCommands.tolerance(units)))
    }

    /// Vectors the same size and outline as the selected ones, anywhere on the design.
    @discardableResult func selectSimilarVectors() -> Bool {
        let refs = selectedShapes
        guard !refs.isEmpty else { NSSound.beep(); return false }
        return selectFound(SelectionQueries.similar(to: refs, in: selectableShapes))
    }

    @discardableResult func invertSelection() -> Bool {
        selectFound(SelectionQueries.inverted(selection, among: selectableShapes))
    }

    @discardableResult func selectShapes(onLayer id: UUID) -> Bool {
        selectFound(selectableShapes.filter { $0.layerID == id }.map(\.id))
    }
}

/// Edit ▸ Select submenu.
struct SelectMenu: View {
    var document: LoftLineDocument?

    var body: some View {
        Menu("Select") {
            Button("Open Vectors") { document?.selectOpenVectors() }
            Button("Duplicate Vectors") { document?.selectDuplicateVectors() }
                .help("Copies lying exactly on top of another vector (the first copy is not selected)")
            Button("Similar Vectors") { document?.selectSimilarVectors() }
                .disabled(document?.selection.isEmpty ?? true)
                .help("Vectors with the same size and outline as the selection")
            Button("Invert Selection") { document?.invertSelection() }
            Menu("All on Layer") {
                ForEach(document?.currentSheetLayers ?? []) { layer in
                    Button(layer.name) { document?.selectShapes(onLayer: layer.id) }
                }
            }
        }
        .disabled(document == nil)
    }
}
