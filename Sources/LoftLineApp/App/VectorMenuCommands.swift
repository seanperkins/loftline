import AppKit
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// The "Vectors" menu: drawing-area tools that act on the selected vectors (kept apart from
/// `LoftLineCommands` so the Design menu stays short).
struct VectorMenuCommands: Commands {
    @FocusedObject private var document: LoftLineDocument?

    var body: some Commands {
        CommandMenu("Vectors") {
            Button("Ungroup All Levels") {
                guard let doc = document else { return }
                let ids = doc.selectedShapes.map(\.id)
                doc.perform("Ungroup All Levels") { $0.document.ungroupAllLevels(ids) }
            }
            .disabled(!(document?.selectedShapes.contains { $0.groupID != nil } ?? false))
            Divider()
            sheetButton("Mirror…", .mirror)
            sheetButton("Shear / Distort…", .distort)
            Button("Distort Envelope on Canvas") { document?.beginEnvelopeEdit() }
                .disabled(noSelection)
                .help("Drag the four corners of the selection's box to bend the vectors")
            Divider()
            sheetButton("Fit Text to Box…", .textFit)
            sheetButton("Text on Curve / Arc…", .textOnCurve)
            Button("Kern Text on Canvas") { document?.beginKerning() }
                .disabled(!(document.map { $0.selectedShapes.count == 1 && $0.selectedShapes[0].text != nil } ?? false))
            Button("Convert Text to Curves") {
                guard let doc = document else { return }
                let ids = doc.selection
                doc.perform("Convert to Curves") { VectorCommands.convertTextToCurves(ids, in: &$0) }
            }
            .disabled(!(document?.selectedShapes.contains { $0.text != nil } ?? false))
            Divider()
            sheetButton("Rectangular Array…", .arrayLinear)
            sheetButton("Circular Array…", .arrayCircular)
            sheetButton("Copy Along Vector…", .copyAlong)
            sheetButton("Vector Texture…", .vectorTexture)
            sheetButton("Boundary Around Selection…", .boundary)
            sheetButton("Plaque Border…", .plaque)
            Divider()
            Button("Trim Tool") { document?.activeTool = .trim }.disabled(document == nil)
            sheetButton("Trim to Boundary…", .trimBoundary)
            Button("Extend to Nearest Vector") {
                guard let doc = document else { return }
                let ids = doc.selectedShapes.map(\.id)
                var n = 0
                doc.perform("Extend") { n = VectorCommands.extendToBoundaries(ids, in: &$0) }
                if n == 0 { NSSound.beep() }
            }
            .disabled(noSelection)
            .help("Extend the ends of the selected open vectors until they meet another vector")
            Divider()
            sheetButton("Trace Bitmap…", .traceBitmap, needsSelection: false)
            sheetButton("Fit Curves to Vectors…", .curveFit)
            sheetButton("Offset Open Vectors…", .offsetOpen)
            sheetButton("Fillet / Chamfer Corners…", .filletChamfer)
            sheetButton("Dog-bone Fillets…", .dogbone)
            sheetButton("Straight-Wall Inlay Offsets…", .inlayOffset)
            Divider()
            Toggle("Snap to Guides", isOn: Binding(get: { document?.snapToGuides ?? true }, set: { document?.snapToGuides = $0 }))
            Button("Clear Guides") { document?.perform("Clear Guides") { $0.document.guides = nil } }
                .disabled(document?.document.guides?.isEmpty ?? true)
            Divider()
            sheetButton("Validate Vectors…", .validator, needsSelection: false)
            Button("Delete Duplicate Vectors") { document?.deleteDuplicateVectors() }
                .disabled(document?.document.shapes.isEmpty ?? true)
                .help("Delete vectors lying on top of others (selection, or the whole design)")
            Button("Clear Problem Markers") { document?.highlightMarkers = [] }
                .disabled(document?.highlightMarkers.isEmpty ?? true)
        }
    }

    private var noSelection: Bool { document?.selection.isEmpty ?? true }

    private func sheetButton(_ title: String, _ kind: DrawingSheet, needsSelection: Bool = true) -> some View {
        Button(title) { document?.sheet = .drawing(kind) }
            .disabled(document == nil || (needsSelection && noSelection))
    }
}
