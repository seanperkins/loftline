import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Shows the dialog for a `DrawingSheet`.
struct DrawingSheetHost: View {
    @ObservedObject var document: LoftLineDocument
    var kind: DrawingSheet

    var body: some View {
        switch kind {
        case .dogbone: DogboneSheet(document: document)
        case .arrayLinear: RectangularArraySheet(document: document)
        case .validator: VectorValidatorSheet(document: document)
        case .mirror: MirrorSheet(document: document)
        case .trimBoundary: TrimBoundarySheet(document: document)
        case .filletChamfer: FilletChamferSheet(document: document)
        case .arrayCircular: CircularArraySheet(document: document)
        case .curveFit: CurveFitSheet(document: document)
        case .textFit: TextFitSheet(document: document)
        case .textOnCurve: TextOnCurveSheet(document: document)
        case .traceBitmap: TraceBitmapSheet(document: document)
        case .distort: DistortSheet(document: document)
        case .offsetOpen: OpenOffsetSheet(document: document)
        case .inlayOffset: StraightInlaySheet(document: document)
        case .copyAlong: CopyAlongSheet(document: document)
        case .vectorTexture: VectorTextureSheet(document: document)
        case .boundary: BoundarySheet(document: document)
        case .plaque: PlaqueSheet(document: document)
        case .joinVectors: JoinVectorsSheet(document: document)
        }
    }
}

/// Common dialog frame: title, form content, Cancel / action buttons.
struct DrawingDialog<Content: View>: View {
    var title: String
    var action: String
    var disabled = false
    var note: String?
    var perform: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Form { content }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { perform(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: Fillet / chamfer

struct FilletChamferSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var chamfer = false
    @State private var size: Double

    init(document: LoftLineDocument) {
        self.document = document
        _size = State(initialValue: document.units == .inch ? 0.25 : 6)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let nodes = document.activeTool == .nodeEdit ? document.nodeSelection : []
        DrawingDialog(title: "Fillet / Chamfer", action: chamfer ? "Chamfer" : "Fillet", disabled: size <= 0 || (ids.isEmpty && nodes.isEmpty),
                      note: (nodes.isEmpty ? "Every corner between two straight segments of the selected vectors is changed."
                             : "The \(nodes.count) selected node\(nodes.count == 1 ? "" : "s") are changed.")
                          + " Corners whose edges are too short are skipped.",
                      perform: {
                          let kind: CornerOps.Kind = chamfer ? .chamfer(distance: size) : .fillet(radius: size)
                          document.perform(chamfer ? "Chamfer" : "Fillet") {
                              VectorCommands.treatCorners(kind, shapes: ids, nodes: nodes, in: &$0)
                          }
                          document.nodeSelection = []
                      }) {
            Picker("Corner", selection: $chamfer) {
                Text("Fillet (round)").tag(false)
                Text("Chamfer (bevel)").tag(true)
            }
            .pickerStyle(.segmented)
            LengthField(chamfer ? "Distance" : "Radius", value: $size, units: document.units)
        }
    }
}

// MARK: Curve fitting

struct CurveFitSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var tolerance: Double

    init(document: LoftLineDocument) {
        self.document = document
        _tolerance = State(initialValue: document.units == .inch ? 0.002 : 0.05)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let before = CurveFit.segmentCount(document.selectedShapes.flatMap(\.paths))
        DrawingDialog(title: "Fit Curves to Vectors", action: "Fit", disabled: ids.isEmpty || tolerance <= 0,
                      note: "Replaces runs of short segments (traced, scanned or DXF data) with lines and circular arcs within the tolerance, which gives smoother cuts and shorter G-code. The selection has \(before) segments.",
                      perform: {
                          let t = tolerance
                          document.perform("Fit Curves") { VectorCommands.fitCurves(ids, tolerance: t, in: &$0) }
                      }) {
            LengthField("Tolerance", value: $tolerance, units: document.units, help: "Largest allowed distance from the original points")
        }
    }
}

// MARK: Dog-bones

struct DogboneSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var diameter: Double
    @State private var style = Dogbone.Style.dogbone
    @State private var side = Dogbone.CutSide.part
    @State private var maxAngle = 135.0

    init(document: LoftLineDocument) {
        self.document = document
        _diameter = State(initialValue: document.units == .inch ? 0.25 : 6)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let count = document.project.document.shapes(ids: ids).reduce(0) {
            $0 + Dogbone.reliefCount($1.paths, radius: diameter / 2, style: style, side: side, maxAngle: maxAngle)
        }
        DrawingDialog(title: "Dog-bone Fillets", action: "Add Relief", disabled: count == 0 || diameter <= 0,
                      note: "Adds a round over-cut at each inside corner the cutter cannot reach, so square-cornered parts fit. \(count) corner\(count == 1 ? "" : "s") will be relieved.",
                      perform: {
                          let d = diameter, st = style, sd = side, a = maxAngle
                          document.perform("Dog-bone Fillets") {
                              VectorCommands.dogbone(ids, toolDiameter: d, style: st, side: sd, maxAngle: a, in: &$0)
                          }
                      }) {
            LengthField("Tool diameter", value: $diameter, units: document.units)
            Picker("Style", selection: $style) {
                Text("Dog-bone").tag(Dogbone.Style.dogbone)
                Text("T-bone (long edge)").tag(Dogbone.Style.tBoneLong)
                Text("T-bone (short edge)").tag(Dogbone.Style.tBoneShort)
            }
            Picker("Vectors are", selection: $side) {
                Text("Parts (cut outside)").tag(Dogbone.CutSide.part)
                Text("Openings (cut inside)").tag(Dogbone.CutSide.opening)
            }
            NumberField("Max corner angle", value: $maxAngle, unit: "°", help: "Corners wider than this are left alone")
        }
    }
}

/// Arrange > Join Open Vectors…: joins open vectors whose ends meet within a tolerance, and says
/// how far ends will move and what still will not join before anything changes.
struct JoinVectorsSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var tolerance: Double

    init(document: LoftLineDocument) {
        self.document = document
        _tolerance = State(initialValue: DesignCommands.defaultJoinTolerance(document.units))
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let preview = tolerance > 0 ? DesignCommands.joinPreview(ids, tolerance: tolerance, in: document.project) : nil
        let note = preview?.lines(units: document.units).joined(separator: "\n")
            ?? (tolerance > 0 ? "The selection has no open vectors to join." : "Enter a tolerance above zero.")
        DrawingDialog(title: "Join Open Vectors", action: "Join", disabled: preview == nil, note: note,
                      perform: {
                          let tol = tolerance
                          var newID: UUID?
                          document.perform("Join") { newID = DesignCommands.join(ids, tolerance: tol, in: &$0) }
                          if let id = newID { document.setSelection([id]) }
                      }) {
            LengthField("Join gaps up to", value: $tolerance, units: document.units)
        }
    }
}
