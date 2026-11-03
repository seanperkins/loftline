import CADCore
import CAMCore
import Foundation

/// Double-sided jobs: which side operations belong to and the per-side output project.
extension LoftLineProject {
    static let bottomLayerName = "Bottom Side"

    /// Side an operation machines (from its vectors' layers). nil = vectors on both sides.
    /// Operations without vectors (3D relief) are on the top side.
    func side(of op: AnyOperation) -> JobSide? {
        guard document.job.isTwoSided else { return .top }
        return document.side(ofShapes: op.setup.shapeIDs)
    }


    /// Job setup an operation is machined with (its sheet and side), or an error message.
    func machiningJob(for op: AnyOperation) -> Result<JobSetup, ToolpathSetupError> {
        guard let sheet = sheetID(of: op) else { return .failure(.sheets) }
        guard let job = document.job(ofSheet: sheet) else { return .failure(.sheets) }
        guard job.isTwoSided else { return .success(job) }
        var d = document
        d.job = job
        guard let side = d.side(ofShapes: op.setup.shapeIDs) else { return .failure(.sides) }
        return .success(job.forSide(side))
    }

    /// What is exported for one side of the current sheet: those operations and their Z zero.
    func sideProject(_ side: JobSide) -> LoftLineProject {
        guard document.job.isTwoSided || document.isMultiSheet else { return self }
        var p = self
        p.document.job = document.job.forSide(side)
        p.operations = operations.filter {
            self.sheetID(of: $0) == document.currentSheetID && (!document.job.isTwoSided || self.side(of: $0) == side)
        }
        return p
    }

    /// Project for one export, shared by the app and the command line: a single toolpath uses its own sheet and side,
    /// "all" the project as seen from `side`.
    func exportProject(for scope: GCodeExportScope, side: JobSide) -> LoftLineProject {
        if case .operation(let id) = scope, let op = operations.first(where: { $0.id == id }) {
            // The toolpath was calculated against its own sheet's job (thickness, Z zero, safe Z);
            // the post, validator and footer must use the same one, not the sheet being shown.
            var p = self
            if case .success(let job) = machiningJob(for: op) { p.document.job = job }
            p.operations = [op]
            return p
        }
        return sideProject(side)
    }

    /// Makes sure a two-sided job has a layer for the bottom side.
    mutating func ensureBottomLayer() {
        let sheet = document.currentSheetID
        guard document.job.isTwoSided, !document.layers.contains(where: {
            $0.side == .bottom && ($0.sheetID ?? MaterialSheet.primaryID) == sheet
        }) else { return }
        let id = addLayer(named: Self.bottomLayerName)
        if let i = document.layers.firstIndex(where: { $0.id == id }) {
            document.layers[i].side = .bottom
            document.layers[i].sheetID = document.activeSheetID
        }
    }
}

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

extension JobSide {
    var displayName: String { self == .top ? "Top" : "Bottom" }
}

extension FlipAxis {
    var displayName: String { self == .leftRight ? "Left–right (about Y)" : "Top–bottom (about X)" }
}

enum ToolpathSetupError: Error {
    case sides, sheets

    var message: String {
        switch self {
        case .sides: return "The toolpath's vectors are on both sides of a two-sided job."
        case .sheets: return "The toolpath's vectors are on more than one material sheet."
        }
    }
}
