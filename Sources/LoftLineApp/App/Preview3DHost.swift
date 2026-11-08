import AppKit
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Hosts the 3D material-removal simulation (Sources/LoftLineApp/Preview/) for the document's
/// calculated toolpaths (all, visible or selected; see `PreviewScope`). The 2D overlay is drawn
/// by the design canvas itself.
struct Preview3DHost: View {
    @ObservedObject var document: LoftLineDocument
    @AppStorage(GCodeExporter.groupByToolKey) private var groupByTool = false
    @AppStorage(PreviewScope.storageKey) private var scope = PreviewScope.all

    /// Visible design vectors on the shown side / sheet, flattened. Always passed: the 3D view also shows them while
    /// drawing or selecting with the preference off.
    var vectors: [[Vec2]] {
        let project = document.outputProject
        return Self.flattened(project.document.shapes.filter { project.isVisible($0) && document.isOnActiveSide($0) })
    }

    /// Selected vectors, flattened, for highlighting in 3D.
    var selectedVectors: [[Vec2]] {
        Self.flattened(document.selectedShapes)
    }

    private static func flattened(_ shapes: [Shape]) -> [[Vec2]] {
        shapes.flatMap(\.paths).compactMap { path in
            var pts = path.flattened(tolerance: 0.005)
            if path.isClosed, let first = pts.first { pts.append(first) }
            return pts.count >= 2 ? pts : nil
        }
    }

    /// A polyline drawn in the 3D view becomes a shape on the current layer (one undo step).
    private func addDrawnShape(_ points: [Vec2], closed: Bool) {
        guard let s = Preview3DDrawing.shape(points: points, closed: closed, layerID: document.currentLayerID)
        else { return }
        document.addShape(s, actionName: "Draw \(s.name) in 3D")
    }

    /// Select-tool click: the shape under the point, as the 2D canvas would pick it; empty clears.
    private func select(at p: Vec2, tolerance: Double) {
        let project = document.project
        let shapes = project.document.shapes.filter { project.isEditable($0) && document.isOnActiveSide($0) }
        if let id = Preview3DDrawing.pickShape(at: p, in: shapes, tolerance: tolerance) {
            document.select(id, extending: NSEvent.modifierFlags.contains(.shift))
        } else if !NSEvent.modifierFlags.contains(.shift) {
            document.clearSelection()
        }
    }

    /// Calculated toolpaths of the chosen scope, in machining order.
    var toolpaths: [Toolpath] {
        scope.toolpaths(operations: document.outputProject.operations, results: document.results,
                        hidden: document.hiddenToolpaths, selected: document.selectedOperationID,
                        groupByTool: groupByTool)
    }

    var body: some View {
        SimulationPreviewView(
            job: document.outputProject.document.job, units: document.document.units, toolpaths: toolpaths,
            rapidRate: SimulationPreviewView.rapidRate(for: document.postProfile, units: document.document.units),
            scope: $scope, emptyMessage: scope.emptyMessage, documentName: document.document.name,
            vectors: vectors, selectedVectors: selectedVectors,
            clamps: ClampList.items(in: document.outputProject.document),
            onDrawShape: { addDrawnShape($0, closed: $1) },
            onSelectAt: { select(at: $0, tolerance: $1) })
    }
}
