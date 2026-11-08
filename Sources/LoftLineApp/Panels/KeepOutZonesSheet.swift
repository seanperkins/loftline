import AppKit
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Keep-out zones made from closed vectors (toolpaths-2d).
enum KeepOutEditing {
    /// One zone per closed path of `shapes` (flattened), named after the shape.
    static func zones(from shapes: [Shape], height: Double, tolerance: Double, existing: Int) -> [KeepOutZone] {
        var out: [KeepOutZone] = []
        for s in shapes {
            for path in s.paths where path.isClosed {
                let pts = path.flattened(tolerance: tolerance)
                guard pts.count > 2 else { continue }
                let loop = pts.first == pts.last ? Array(pts.dropLast()) : pts
                let base = s.name.isEmpty ? "Zone" : s.name
                out.append(KeepOutZone(name: "\(base) \(existing + out.count + 1)", outline: loop, height: height))
            }
        }
        return out
    }
}

struct KeepOutZonesSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss

    private var zones: [KeepOutZone] { document.document.keepOutZones ?? [] }
    private var units: LengthUnit { document.units }

    private func update(_ change: @escaping (inout [KeepOutZone]) -> Void) {
        document.perform("Edit Keep-Out Zones") { p in
            var z = p.document.keepOutZones ?? []
            change(&z)
            p.document.keepOutZones = z.isEmpty ? nil : z
        }
    }

    private func binding<T>(_ id: UUID, _ kp: WritableKeyPath<KeepOutZone, T>) -> Binding<T> {
        Binding(get: { zones.first { $0.id == id }![keyPath: kp] }, set: { v in
            update { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i][keyPath: kp] = v } }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keep-Out Zones").font(.title2.bold()).padding([.horizontal, .top], 20)
            Form {
                Section {
                    if zones.isEmpty {
                        Text("No keep-out zones.").foregroundStyle(.secondary)
                    }
                    ForEach(zones) { z in
                        HStack {
                            TextField("Name", text: binding(z.id, \.name)).frame(minWidth: 140)
                            LengthField("Height", value: binding(z.id, \.height), units: units,
                                        help: "Top of the clamp above the material top")
                            Toggle("Lift over", isOn: Binding(get: { zones.first { $0.id == z.id }?.liftOver ?? false },
                                                              set: { v in update { list in
                                                                  if let i = list.firstIndex(where: { $0.id == z.id }) { list[i].liftOver = v ? true : nil }
                                                              } }))
                                .help("Re-route toolpaths up and over this zone; the material under it is left uncut")
                            Button { update { $0.removeAll { $0.id == z.id } } } label: { Image(systemName: "trash") }
                                .buttonStyle(.icon).help("Delete zone")
                        }
                    }
                } footer: {
                    Text("Export and Check Toolpaths report an error when a toolpath or rapid comes within the tool radius (+ \(units == .inch ? "0.05 in" : "1 mm")) of a zone while lower than its top (+ the same clearance). Zones are drawn hatched in red on the canvas and are never cut. With \"Lift over\" on, toolpaths retract over the zone instead (up to its top + twice the clearance, across, then plunge back at the plunge rate), so recalculate and check the part: anything under the zone is not cut.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Add From Selected Vectors (\(document.selectedShapes.count))") {
                    let tol = units == .inch ? 0.0005 : 0.01
                    let new = KeepOutEditing.zones(from: document.selectedShapes, height: units == .inch ? 1 : 25,
                                                   tolerance: tol, existing: zones.count)
                    update { $0 += new }
                }
                .disabled(document.selectedShapes.isEmpty)
                Spacer()
                DismissButton("Done") { dismiss() }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

extension CanvasNSView {
    /// Keep-out zones: translucent red fill, hatching and a dashed outline.
    func drawKeepOutZones(_ ctx: CGContext, _ doc: LoftLineDocument, _ vt: CGAffineTransform) {
        guard let zones = doc.document.keepOutZones, !zones.isEmpty else { return }
        let red = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.1, alpha: 1)
        for z in zones where z.isUsable {
            let path = CGMutablePath()
            path.addLines(between: z.outline.map { CGPoint(x: $0.x, y: $0.y).applying(vt) })
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(red.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            // Hatching clipped to the zone.
            ctx.addPath(path)
            ctx.clip()
            let box = path.boundingBox
            ctx.setStrokeColor(red.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1)
            var x = box.minX - box.height
            while x < box.maxX {
                ctx.move(to: CGPoint(x: x, y: box.minY))
                ctx.addLine(to: CGPoint(x: x + box.height, y: box.maxY))
                x += 8
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(red.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
