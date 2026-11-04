import CADCore
import CAMCore
import Foundation
import LoftLineKit

extension LoftLineDocument {
    /// The project export, validation, previews and the job sheet use: the side being shown
    /// when the job is two-sided, otherwise the whole project.
    var outputProject: LoftLineProject { project.sideProject(activeSide) }

    var isTwoSided: Bool { document.job.isTwoSided }

    /// Project for one export: a single toolpath uses its own side, "all" the shown side.
    func outputProject(for scope: GCodeExportScope) -> LoftLineProject { project.exportProject(for: scope, side: activeSide) }

    /// True when the shape is in view: on the current sheet and, for two-sided jobs, the shown side.
    func isOnActiveSide(_ shape: Shape) -> Bool {
        (!document.isMultiSheet || document.sheetID(of: shape) == document.currentSheetID)
            && (!isTwoSided || document.side(of: shape) == activeSide)
    }

    func isOnActiveSide(_ op: AnyOperation) -> Bool {
        (!document.isMultiSheet || project.sheetID(of: op) == document.currentSheetID)
            && (!isTwoSided || project.side(of: op) == activeSide)
    }

    /// Layers shown in the sidebar: those of the current sheet.
    var currentSheetLayers: [Layer] {
        guard document.isMultiSheet else { return document.layers }
        return document.layers.filter { document.sheetID(ofLayer: $0.id) == document.currentSheetID }
    }

    /// Shows the other side (selection is cleared: shapes on the hidden side cannot be edited).
    func showSide(_ side: JobSide) {
        guard isTwoSided, side != activeSide else { return }
        clearSelection()
        activeSide = side
    }

    /// Moves a layer to a side (one undo step).
    func setLayerSide(_ layerID: UUID, _ side: JobSide) {
        perform("Move Layer to \(side == .top ? "Top" : "Bottom") Side") { p in
            if let i = p.document.layers.firstIndex(where: { $0.id == layerID }) {
                p.document.layers[i].side = side == .top ? nil : .bottom
            }
        }
    }
}
