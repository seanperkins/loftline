import CADCore
import SwiftUI
import LoftLineKit

// Tool database addition (toolpaths-2d): bull-nose, tapered ball-nose and form-tool outlines.

/// Which outline the editor's Shape picker shows.
enum ToolShapeChoice: String, CaseIterable, Identifiable {
    case standard, bullNose, tapered, form
    var id: String { rawValue }

    static func choices(for kind: ToolKind) -> [ToolShapeChoice] {
        switch kind {
        case .endMill: return [.standard, .bullNose, .form]
        case .ballNose: return [.standard, .tapered, .form]
        default: return []
        }
    }

    func title(for kind: ToolKind) -> String {
        switch self {
        case .standard: return kind == .ballNose ? "Ball" : "Square"
        case .bullNose: return "Bull Nose"
        case .tapered: return "Tapered"
        case .form: return "Form"
        }
    }

    init(_ shape: CutterShape?) {
        switch shape {
        case .bullNose?: self = .bullNose
        case .taperedBallNose?: self = .tapered
        case .form?: self = .form
        case nil: self = .standard
        }
    }

    /// A sensible starting outline for `tool`.
    func defaultShape(for tool: Tool) -> CutterShape? {
        let r = tool.radius
        switch self {
        case .standard: return nil
        case .bullNose: return .bullNose(cornerRadius: (r / 4 * 1000).rounded() / 1000)
        case .tapered: return .taperedBallNose(tipRadius: (r / 4 * 1000).rounded() / 1000, halfAngle: 5)
        case .form: return .form(points: ToolShapePresets.roundover(toolRadius: r, roundoverRadius: r / 2))
        }
    }
}

enum ToolShapePresets {
    /// Bottom-bearing-less roundover outline: a quarter circle of `rr` cut into the corner of a
    /// cylinder of `toolRadius` (pilot/flat at the tip, widening up to the full radius).
    static func roundover(toolRadius R: Double, roundoverRadius rr: Double, segments: Int = 8) -> [FormToolPoint] {
        let rr = min(max(rr, 0), R)
        let inner = R - rr
        var pts = [FormToolPoint(height: 0, radius: inner)]
        for k in 1...segments {
            let a = Double(k) / Double(segments) * .pi / 2
            // Concave quarter arc centred at (radius R, height 0): radius R − rr·cos(a), height rr·sin(a)
            pts.append(FormToolPoint(height: rr * sin(a), radius: R - rr * cos(a)))
        }
        pts.append(FormToolPoint(height: rr + R, radius: R))
        return pts
    }
}

struct ToolShapeSection: View {
    @Binding var tool: Tool

    var body: some View {
        let choices = ToolShapeChoice.choices(for: tool.kind)
        if !choices.isEmpty {
            Section("Shape") {
                Picker("Shape", selection: Binding(get: { ToolShapeChoice(tool.shape) },
                                                   set: { tool.shape = $0.defaultShape(for: tool) })) {
                    ForEach(choices) { Text($0.title(for: tool.kind)).tag($0) }
                }
                .pickerStyle(.segmented)
                editor
                if let s = tool.shape, let p = s.problem(toolRadius: tool.radius) {
                    Text(p + " The plain shape is used until this is fixed.").font(.caption).foregroundStyle(Color.warningText)
                }
                ToolSilhouetteView(tool: tool).frame(height: 110)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        let u = tool.units
        switch tool.shape {
        case .bullNose(let c)?:
            LengthField("Corner radius", value: Binding(get: { c }, set: { tool.shape = .bullNose(cornerRadius: $0) }), units: u,
                        help: "Radius of the rounded bottom corners; at most half the diameter")
        case .taperedBallNose(let tip, let half)?:
            LengthField("Tip radius", value: Binding(get: { tip }, set: { tool.shape = .taperedBallNose(tipRadius: $0, halfAngle: half) }),
                        units: u, help: "Radius of the ball at the tip")
            NumberField("Taper angle (per side)", value: Binding(get: { half }, set: { tool.shape = .taperedBallNose(tipRadius: tip, halfAngle: $0) }),
                        unit: "°", help: "Angle of each flank from the tool axis")
            Text("Diameter is the widest cutting diameter (where the taper ends).").font(.caption).foregroundStyle(.secondary)
        case .form(let pts)?:
            FormPointsEditor(points: Binding(get: { pts }, set: { tool.shape = .form(points: $0) }), units: u, toolRadius: tool.radius)
        default:
            EmptyView()
        }
    }
}

private struct FormPointsEditor: View {
    @Binding var points: [FormToolPoint]
    var units: LengthUnit
    var toolRadius: Double
    @State private var roundover: Double = 0

    var body: some View {
        Text("Outline from the tip upward: cutting radius at each height above the tip.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(points.indices, id: \.self) { i in
            HStack {
                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
                TextField("Height", value: Binding(get: { points[safe: i]?.height ?? 0 }, set: { v in if points.indices.contains(i) { points[i].height = v } }),
                          format: decimalFormat).multilineTextAlignment(.trailing)
                Text("high, radius").foregroundStyle(.secondary)
                TextField("Radius", value: Binding(get: { points[safe: i]?.radius ?? 0 }, set: { v in if points.indices.contains(i) { points[i].radius = v } }),
                          format: decimalFormat).multilineTextAlignment(.trailing)
                Text(units.abbreviation).foregroundStyle(.secondary)
                Button { points.remove(at: i) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.icon).disabled(points.count <= 2)
            }
        }
        HStack {
            Button("Add Point") {
                let last = points.last ?? FormToolPoint(height: 0, radius: toolRadius)
                points.append(FormToolPoint(height: last.height + toolRadius / 2, radius: toolRadius))
            }
            Spacer()
            TextField("Roundover radius", value: $roundover, format: decimalFormat).frame(maxWidth: 70)
                .multilineTextAlignment(.trailing)
            Button("Roundover Preset") {
                points = ToolShapePresets.roundover(toolRadius: toolRadius, roundoverRadius: roundover > 0 ? roundover : toolRadius / 2)
            }
            .help("Replaces the outline with a roundover of this radius")
        }
    }
}

/// Side view of the cutter outline (tip at the bottom), for checking a shape at a glance.
struct ToolSilhouetteView: View {
    var tool: Tool

    var body: some View {
        Canvas { ctx, size in
            let R = max(tool.radius, 1e-9)
            let n = 48
            let samples = (0...n).map { k -> (Double, Double) in
                let r = R * Double(k) / Double(n)
                return (r, tool.heightAboveTip(atRadius: r) ?? 0)
            }
            let top = max(samples.map(\.1).max() ?? 0, R) * 1.25
            let scale = min(size.width / (2 * R) * 0.8, size.height / top * 0.9)
            let cx = size.width / 2, base = size.height - 4
            func pt(_ r: Double, _ h: Double) -> CGPoint { CGPoint(x: cx + r * scale, y: base - h * scale) }
            var path = SwiftUI.Path()
            path.move(to: pt(-R, top))
            for (r, h) in samples.reversed() { path.addLine(to: pt(-r, h)) }
            for (r, h) in samples { path.addLine(to: pt(r, h)) }
            path.addLine(to: pt(R, top))
            ctx.fill(path, with: .color(.secondary.opacity(0.25)))
            ctx.stroke(path, with: .color(.primary), lineWidth: 1)
        }
        .accessibilityLabel("Cutter outline")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
