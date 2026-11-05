import CADCore
import CAMCore
import Foundation
import LoftLineKit

extension LoftLineDocument {
    /// Shows draggable envelope corners on the canvas for the selection.
    func beginEnvelopeEdit(offsets: [Vec2]? = nil) {
        guard let e = EnvelopeEdit(selectionOrder.isEmpty ? Array(selection) : selectionOrder, in: project, offsets: offsets) else {
            report(AlertMessage(title: "Distort", message: "Select one or more editable vectors with a width and height first."))
            return
        }
        activeTool = .select
        kerningShapeID = nil
        tabEditingOperationID = nil
        envelopeEdit = e
    }

    /// Bends the vectors to the dragged quad (one "Distort" undo step) and ends the edit.
    func applyEnvelopeEdit() {
        guard let e = envelopeEdit else { return }
        envelopeEdit = nil
        guard !e.isIdentity else { return }
        perform("Distort") { VectorCommands.envelope(e.shapeIDs, offsets: e.offsets, in: &$0) }
    }

    func cancelEnvelopeEdit() { envelopeEdit = nil }
}
