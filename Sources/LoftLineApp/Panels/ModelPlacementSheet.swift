import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// "Place 3D Model": size, position and Z placement of an imported STL, plus optional
/// Roughing + Finishing toolpaths.
struct ModelPlacementSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var form: ModelPlacementForm
    private let isNew: Bool

    init(document: LoftLineDocument, form: ModelPlacementForm) {
        self.document = document
        _form = State(initialValue: form)
        isNew = document.document.model(id: form.modelID) == nil
    }

    private var units: LengthUnit { document.units }
    private var library: ToolLibrary { document.mergedLibrary }
    private func label(_ v: Double) -> String { RulerTicks.label((v * 1000).rounded() / 1000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(isNew ? "Place 3D Model" : "Edit 3D Model").font(.title2.bold()); Spacer(); HelpButton(topic: .relief3D) }
                .padding([.horizontal, .top], 20)
            Text("\(form.name) · \(form.mesh.triangleCount) triangles · original size \(label(form.meshSize.x)) x \(label(form.meshSize.y)) x \(label(form.meshSize.z)) \(units.abbreviation)")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 4)
            Form {
                Section("Size (aspect ratio locked)") {
                    TextField("Name", text: $form.name)
                    LengthField("Width (X)", value: Binding(get: { form.width }, set: { form.setWidth($0) }), units: units)
                    LengthField("Height (Y)", value: Binding(get: { form.height }, set: { form.setHeight($0) }), units: units)
                }
                Section("Position") {
                    Picker("Place at", selection: $form.position) {
                        ForEach(ModelPlacementForm.Position.allCases) { Text($0.title).tag($0) }
                    }
                    if form.position == .custom {
                        LengthField("Left (X)", value: $form.x, units: units, help: "Material frame, from the lower-left corner")
                        LengthField("Bottom (Y)", value: $form.y, units: units)
                    } else {
                        let o = form.origin
                        Text("Lower-left corner at X \(label(o.x)), Y \(label(o.y))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Position in material (Z)") {
                    LengthField("Model depth (Z)", value: $form.zHeight, units: units,
                                help: "Height of the model from its lowest to its highest point")
                    HStack {
                        Text("Place at")
                        Spacer()
                        ForEach(ModelPlacementForm.ZAnchor.allCases) { a in
                            Button(a.title) { form.anchor(a) }
                        }
                    }
                    LengthField("Gap above", value: $form.gapAbove, units: units,
                                help: "Material left above the model's highest point (Z offset below the top)")
                    LengthField("Gap below", value: $form.gapBelow, units: units,
                                help: "Material left under the model's lowest point")
                    Button("Fit Depth Between Gaps") { form.fillBetweenGaps(above: form.gapAbove, below: max(form.gapBelow, 0)) }
                        .help("Stretch the model's Z height so it fills the material between the two gaps")
                    ModelGapDiagram(thickness: form.job.thickness, gapAbove: form.gapAbove, height: form.zHeight)
                        .frame(height: 54)
                    Text("Deepest cut: \(label(form.zOffset + form.zHeight)) \(units.abbreviation) of \(label(form.job.thickness)) \(units.abbreviation) material")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Toolpaths") {
                    Toggle(isNew ? "Create Roughing + Finishing toolpaths" : "Also create Roughing + Finishing toolpaths",
                           isOn: $form.createToolpaths)
                    if form.createToolpaths {
                        OptionalToolPicker(title: "Roughing tool", toolID: $form.roughingToolID, library: library, kinds: [.endMill])
                        OptionalToolPicker(title: "Finishing tool", toolID: $form.finishingToolID, library: library,
                                           kinds: [.ballNose, .endMill, .vBit])
                    }
                }
                if !form.warnings.isEmpty {
                    Section {
                        ForEach(form.warnings, id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(isNew ? "Don't Import" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Place Model" : "Apply") {
                    document.applyPlacement(form)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.zHeight <= 0 || form.width <= 0)
            }
            .padding(20)
        }
        .frame(width: 520, height: 680)
    }
}

/// Side view of the material with the model's Z band and the gaps above/below it.
struct ModelGapDiagram: View {
    var thickness: Double
    var gapAbove: Double
    var height: Double

    var body: some View {
        Canvas { ctx, size in
            let t = max(thickness, 1e-9)
            let stock = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            ctx.fill(SwiftUI.Path(stock), with: .color(Color(red: 0.93, green: 0.86, blue: 0.72)))
            let top = CGFloat(min(max(gapAbove / t, 0), 1)) * size.height
            let h = CGFloat(min(max(height / t, 0), 2)) * size.height
            let band = CGRect(x: size.width * 0.1, y: top, width: size.width * 0.8, height: h)
            let over = band.maxY > size.height + 0.5
            ctx.fill(SwiftUI.Path(band), with: .color((over ? Color.red : Color.accentColor).opacity(0.45)))
            ctx.stroke(SwiftUI.Path(stock), with: .color(.secondary), lineWidth: 1)
        }
        .clipped()
        .help("Side view: material (tan) and the model's depth band")
    }
}
