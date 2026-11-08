import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

struct TrimBoundarySheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var keepInside = true

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let boundary = document.selectedShapes.first { $0.paths.contains(where: \.isClosed) }
        DrawingDialog(title: "Trim to Boundary", action: "Trim", disabled: boundary == nil,
                      note: boundary == nil ? "Select a closed boundary vector first."
                          : "Boundary: \(boundary!.name.isEmpty ? "first selected closed vector" : boundary!.name). "
                          + (ids.count > 1 ? "The other selected vectors are trimmed." : "Every editable vector is trimmed."),
                      perform: {
                          let k = keepInside
                          document.perform("Trim to Boundary") { VectorCommands.trimToBoundary(ids, keepInside: k, in: &$0) }
                      }) {
            Picker("Keep", selection: $keepInside) {
                Text("Inside").tag(true)
                Text("Outside").tag(false)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct DistortSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var envelope = false
    @State private var shearX = 15.0
    @State private var shearY = 0.0
    @State private var offsets = [Vec2](repeating: .zero, count: 4)

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let units = document.units
        DrawingDialog(title: "Shear / Distort", action: envelope ? "Distort" : "Shear", disabled: ids.isEmpty,
                      note: envelope ? "Moves the corners of the selection's bounding box and bends the vectors to follow (curves are refitted as lines and arcs; live text becomes curves)."
                          : "Slants the selection about its center. Positive X slants the top to the right; positive Y raises the right side.",
                      perform: {
                          if envelope {
                              let o = offsets
                              document.perform("Distort") { VectorCommands.envelope(ids, offsets: o, in: &$0) }
                          } else {
                              let (x, y) = (shearX, shearY)
                              document.perform("Shear") { VectorCommands.shear(ids, xDegrees: x, yDegrees: y, in: &$0) }
                          }
                      }) {
            Picker("Mode", selection: $envelope) {
                Text("Shear").tag(false)
                Text("Envelope").tag(true)
            }
            .pickerStyle(.segmented)
            if envelope {
                Button("Drag Corners on Canvas") {
                    let o = offsets
                    // Before the sheet closes: a message it reports (nothing editable selected) waits for the sheet.
                    document.beginEnvelopeEdit(offsets: o)
                    document.sheet = nil
                }
                .disabled(ids.isEmpty)
                .help("Close this dialog and drag the four corners on the design; the vectors are previewed as they bend")
                ForEach(0..<4, id: \.self) { i in
                    let name = ["Lower left", "Lower right", "Upper right", "Upper left"][i]
                    LengthField("\(name) X", value: $offsets[i].x, units: units)
                    LengthField("\(name) Y", value: $offsets[i].y, units: units)
                }
            } else {
                NumberField("Shear X", value: $shearX, unit: "°")
                NumberField("Shear Y", value: $shearY, unit: "°")
            }
        }
    }
}

struct OpenOffsetSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var distance: Double
    @State private var side = VectorCommands.OpenOffsetSide.both

    init(document: LoftLineDocument) {
        self.document = document
        _distance = State(initialValue: document.units == .inch ? 0.125 : 3)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let openCount = document.selectedShapes.reduce(0) { $0 + $1.paths.filter { !$0.isClosed }.count }
        DrawingDialog(title: "Offset Open Vectors", action: "Offset", disabled: openCount == 0 || distance <= 0,
                      note: openCount == 0 ? "Select open vectors (closed ones use Offset…)."
                          : "Left/right follow each vector's direction. The closed outline wraps the vector with round ends — the shape of a cut that wide.",
                      perform: {
                          let (d, s) = (distance, side)
                          var newIDs: [UUID] = []
                          document.perform("Offset Open Vectors") { newIDs = VectorCommands.offsetOpen(ids, distance: d, side: s, in: &$0) }
                          if !newIDs.isEmpty { document.setSelection(newIDs) }
                      }) {
            LengthField("Distance", value: $distance, units: document.units)
            Picker("Offset", selection: $side) {
                ForEach(VectorCommands.OpenOffsetSide.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

struct StraightInlaySheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var diameter: Double
    @State private var clearance: Double
    @State private var mirrorPlug = true

    init(document: LoftLineDocument) {
        self.document = document
        _diameter = State(initialValue: document.units == .inch ? 0.125 : 3)
        _clearance = State(initialValue: document.units == .inch ? 0.005 : 0.1)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let closed = document.selectedShapes.contains(where: \.isClosed)
        DrawingDialog(title: "Straight-Wall Inlay Offsets", action: "Create Pocket & Plug", disabled: !closed || diameter <= 0,
                      note: "Rounds every corner of the design to the end mill radius (so pocket and plug can both be cut), then makes an \"Inlay pocket\" vector (cut as a Pocket) and an \"Inlay plug\" vector beside it (cut with an outside Profile). The clearance is split between them. For V-bit inlays use Toolpaths › Inlay.",
                      perform: {
                          let (d, c, m) = (diameter, clearance, mirrorPlug)
                          var made: (UUID, UUID)?
                          document.perform("Inlay Offsets") { made = VectorCommands.straightInlay(ids, toolDiameter: d, clearance: c, mirrorPlug: m, in: &$0) }
                          if let (a, b) = made { document.setSelection([a, b]) }
                      }) {
            LengthField("End mill diameter", value: $diameter, units: document.units)
            LengthField("Clearance (total)", value: $clearance, units: document.units, help: "Gap between plug and pocket walls, both sides together")
            Toggle("Mirror the plug (glued face down)", isOn: $mirrorPlug)
        }
    }
}

struct BoundarySheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var kind = BoundaryVector.Kind.shrinkWrap
    @State private var margin: Double
    @State private var gap: Double

    init(document: LoftLineDocument) {
        self.document = document
        _margin = State(initialValue: document.units == .inch ? 0.25 : 6)
        _gap = State(initialValue: document.units == .inch ? 0.25 : 6)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        DrawingDialog(title: "Boundary Around Selection", action: "Create Boundary", disabled: ids.isEmpty,
                      note: "Adds a closed vector around the selected objects — e.g. the outline of a sign or a cut-out border.",
                      perform: {
                          let (k, m, g) = (kind, margin, gap)
                          var id: UUID?
                          document.perform("Create Boundary") { id = VectorCommands.boundary(ids, kind: k, margin: m, gap: g, in: &$0) }
                          if let id { document.setSelection([id]) }
                      }) {
            Picker("Shape", selection: $kind) {
                Text("Bounding rectangle").tag(BoundaryVector.Kind.rectangle)
                Text("Convex hull").tag(BoundaryVector.Kind.convexHull)
                Text("Shrink-wrap").tag(BoundaryVector.Kind.shrinkWrap)
            }
            LengthField("Margin", value: $margin, units: document.units)
            if kind == .shrinkWrap {
                LengthField("Bridge gaps up to", value: $gap, units: document.units, help: "Half the width of the gaps the wrap closes over")
            }
        }
    }
}

struct PlaqueSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var style = PlaqueMaker.Style.rounded
    @State private var margin: Double
    @State private var corner: Double
    @State private var border = false
    @State private var inset: Double

    init(document: LoftLineDocument) {
        self.document = document
        let inch = document.units == .inch
        _margin = State(initialValue: inch ? 1 : 25)
        _corner = State(initialValue: inch ? 0.75 : 20)
        _inset = State(initialValue: inch ? 0.375 : 10)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        DrawingDialog(title: "Plaque Border", action: "Create Plaque", disabled: ids.isEmpty,
                      note: "Draws a sign outline around the selected text or artwork (one new shape; the optional inner border is a second vector in it — select it with Break Apart to give it its own toolpath).",
                      perform: {
                          let (s, m, c, i) = (style, margin, corner, border ? inset : 0)
                          var id: UUID?
                          document.perform("Plaque Border") { id = VectorCommands.plaque(ids, style: s, margin: m, corner: c, borderInset: i, in: &$0) }
                          if let id { document.setSelection([id]) }
                      }) {
            Picker("Style", selection: $style) {
                Text("Rectangle").tag(PlaqueMaker.Style.rectangle)
                Text("Rounded corners").tag(PlaqueMaker.Style.rounded)
                Text("Chamfered corners").tag(PlaqueMaker.Style.chamfered)
                Text("Notched corners").tag(PlaqueMaker.Style.notched)
                Text("Ogee corners").tag(PlaqueMaker.Style.ogee)
                Text("Oval").tag(PlaqueMaker.Style.oval)
            }
            LengthField("Margin", value: $margin, units: document.units)
            if style != .rectangle && style != .oval {
                LengthField("Corner size", value: $corner, units: document.units)
            }
            Toggle("Inner border line", isOn: $border)
            if border { LengthField("Border inset", value: $inset, units: document.units) }
        }
    }
}

struct MirrorSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var horizontally = true
    @State private var pivot = VectorCommands.MirrorPivot.selectionCenter
    @State private var keepOriginal = false

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        DrawingDialog(title: "Mirror", action: keepOriginal ? "Mirror Copy" : "Mirror", disabled: ids.isEmpty,
                      note: "Mirroring about the material center flips a design for cutting from the back of the board.",
                      perform: {
                          let (h, p, k) = (horizontally, pivot, keepOriginal)
                          var copies: [UUID]?
                          document.perform(k ? "Mirror Copy" : "Mirror") {
                              copies = VectorCommands.mirror(ids, horizontally: h, pivot: p, keepOriginal: k, in: &$0)
                          }
                          if let c = copies, !c.isEmpty { document.setSelection(c) }
                      }) {
            Picker("Flip", selection: $horizontally) {
                Text("Left ↔ right").tag(true)
                Text("Top ↕ bottom").tag(false)
            }
            .pickerStyle(.segmented)
            Picker("About", selection: $pivot) {
                ForEach(VectorCommands.MirrorPivot.allCases) { Text($0.title(horizontally: horizontally)).tag($0) }
            }
            Toggle("Keep original (mirror copy)", isOn: $keepOriginal)
        }
    }
}
