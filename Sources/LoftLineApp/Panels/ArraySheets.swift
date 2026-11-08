import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

struct VectorTextureSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var options = VectorTexture.Options()

    init(document: LoftLineDocument) {
        self.document = document
        var o = VectorTexture.Options()
        if document.units == .millimeter {
            o.spacing = 6; o.amplitude = 2.5; o.wavelength = 25
        }
        _options = State(initialValue: o)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let closed = document.selectedShapes.contains { $0.paths.contains(where: \.isClosed) }
        let units = document.units
        DrawingDialog(title: "Vector Texture", action: "Create Texture", disabled: !closed || options.spacing <= 0,
                      note: "Fills the selected closed vectors with open pattern lines (one new shape) — e.g. for a V-bit or ball-nose texture with a Profile on the line or Fluting.",
                      perform: {
                          let o = options
                          var id: UUID?
                          document.perform("Vector Texture") { id = VectorCommands.vectorTexture(ids, options: o, in: &$0) }
                          if let id { document.setSelection([id]) }
                      }) {
            Picker("Pattern", selection: $options.pattern) {
                Text("Straight lines").tag(VectorTexture.Pattern.lines)
                Text("Waves").tag(VectorTexture.Pattern.waves)
                Text("Zigzag").tag(VectorTexture.Pattern.zigzag)
            }
            LengthField("Spacing", value: $options.spacing, units: units)
            NumberField("Angle", value: $options.angle, unit: "°")
            if options.pattern != .lines {
                LengthField("Amplitude", value: $options.amplitude, units: units)
                LengthField("Wavelength", value: $options.wavelength, units: units)
                NumberField("Variation", value: $options.variation, help: "0 = regular, 1 = strongly varied (repeatable)")
            }
        }
    }
}

struct CopyAlongSheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var bySpacing = false
    @State private var count = 5
    @State private var spacing: Double
    @State private var rotate = true
    @State private var keepOriginal = false

    init(document: LoftLineDocument) {
        self.document = document
        _spacing = State(initialValue: document.units == .inch ? 1 : 25)
    }

    var body: some View {
        let order = document.selectedShapes.map(\.id)
        let guide = document.selectedShapes.last
        let n = bySpacing ? (guide?.paths.first.map { CopyAlong.count(along: $0, spacing: spacing) } ?? 0) : count
        DrawingDialog(title: "Copy Along Vector", action: "Copy", disabled: order.count < 2 || n < 1,
                      note: order.count < 2 ? "Select the objects, then shift-click the guide vector last."
                          : "Guide: the last selected vector\(guide.map { $0.name.isEmpty ? "" : " (\($0.name))" } ?? ""). \(n) cop\(n == 1 ? "y" : "ies") centered on evenly spaced points; open guides get one at each end.",
                      perform: {
                          let (c, r, k) = (n, rotate, keepOriginal)
                          var ids: [UUID] = []
                          document.perform("Copy Along Vector") { ids = VectorCommands.copyAlong(order, count: c, rotate: r, keepOriginal: k, in: &$0) }
                          if !ids.isEmpty { document.setSelection(ids) }
                      }) {
            Picker("Spacing", selection: $bySpacing) {
                Text("Number of copies").tag(false)
                Text("Distance apart").tag(true)
            }
            if bySpacing {
                LengthField("Distance", value: $spacing, units: document.units)
            } else {
                IntField("Copies", value: $count, range: 1...1000)
            }
            Toggle("Rotate copies to follow the vector", isOn: $rotate)
            Toggle("Keep the original", isOn: $keepOriginal)
        }
    }
}

struct CircularArraySheet: View {
    enum CenterChoice: String, CaseIterable, Identifiable {
        case material, custom
        var id: String { rawValue }
    }

    @ObservedObject var document: LoftLineDocument
    @State private var count = 6
    @State private var evenly = true
    @State private var sweep = 360.0
    @State private var step = 30.0
    @State private var rotate = true
    @State private var centerChoice = CenterChoice.material
    @State private var center: Vec2

    init(document: LoftLineDocument) {
        self.document = document
        _center = State(initialValue: document.document.job.materialBounds.center)
    }

    private var stepValue: Double { evenly ? ArrayLayout.evenStep(count: count, sweepDegrees: sweep) : step }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        DrawingDialog(title: "Circular Array", action: "Create Copies", disabled: count < 2 || ids.isEmpty || stepValue == 0,
                      note: "\(count - 1) copies, \(RulerTicks.label((stepValue * 1000).rounded() / 1000))° apart (positive = counter-clockwise).",
                      perform: {
                          let c = centerChoice == .material ? document.document.job.materialBounds.center : center
                          let (n, s, r) = (count, stepValue, rotate)
                          var newIDs: [UUID] = []
                          document.perform("Circular Array") {
                              newIDs = VectorCommands.circularArray(ids, count: n, center: c, stepDegrees: s, rotateCopies: r, in: &$0)
                          }
                          if !newIDs.isEmpty { document.setSelection(ids + newIDs) }
                      }) {
            IntField("Items (total)", value: $count, range: 2...360)
            Toggle("Spread evenly", isOn: $evenly)
            if evenly {
                NumberField("Over angle", value: $sweep, unit: "°", help: "360° = full circle")
            } else {
                NumberField("Step angle", value: $step, unit: "°")
            }
            Toggle("Rotate copies", isOn: $rotate)
            Picker("Center", selection: $centerChoice) {
                Text("Material center").tag(CenterChoice.material)
                Text("Custom point").tag(CenterChoice.custom)
            }
            if centerChoice == .custom {
                LengthField("Center X", value: $center.x, units: document.units)
                LengthField("Center Y", value: $center.y, units: document.units)
            }
        }
    }
}

struct RectangularArraySheet: View {
    @ObservedObject var document: LoftLineDocument
    @State private var rows = 2
    @State private var columns = 3
    @State private var x: Double
    @State private var y: Double
    @State private var spacing = ArrayLayout.Spacing.gap

    init(document: LoftLineDocument) {
        self.document = document
        let g = document.units == .inch ? 0.25 : 6
        _x = State(initialValue: g)
        _y = State(initialValue: g)
    }

    var body: some View {
        let ids = document.selectedShapes.map(\.id)
        let size = document.project.bounds(of: document.selection).size
        let u = document.units.abbreviation
        DrawingDialog(title: "Rectangular Array", action: "Create Copies", disabled: rows * columns < 2 || ids.isEmpty,
                      note: "Selection is \(RulerTicks.label(size.x)) × \(RulerTicks.label(size.y)) \(u). Columns run right and rows up; use negative distances to go left or down. \(max(0, rows * columns - 1)) copies.",
                      perform: {
                          let (r, c, dx, dy, sp) = (rows, columns, x, y, spacing)
                          var newIDs: [UUID] = []
                          document.perform("Rectangular Array") {
                              newIDs = VectorCommands.rectangularArray(ids, rows: r, columns: c, x: dx, y: dy, spacing: sp, in: &$0)
                          }
                          if !newIDs.isEmpty { document.setSelection(ids + newIDs) }
                      }) {
            IntField("Rows", value: $rows, range: 1...500)
            IntField("Columns", value: $columns, range: 1...500)
            Picker("Spacing", selection: $spacing) {
                Text("Gap between copies").tag(ArrayLayout.Spacing.gap)
                Text("Offset (center to center)").tag(ArrayLayout.Spacing.offset)
            }
            LengthField(spacing == .gap ? "X gap" : "X offset", value: $x, units: document.units)
            LengthField(spacing == .gap ? "Y gap" : "Y offset", value: $y, units: document.units)
        }
    }
}
