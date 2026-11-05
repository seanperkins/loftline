import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Inlay wizard: one set of settings → a female pocket and a mirrored male plug toolpath.
struct InlayWizardSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var model: InlayWizardModel

    init(document: LoftLineDocument) {
        self.document = document
        _model = State(initialValue: InlayWizardModel(project: document.project, library: document.mergedLibrary,
                                                      shapeIDs: document.selectedShapes.filter(\.isClosed).map(\.id)))
    }

    private var units: LengthUnit { document.units }
    private var library: ToolLibrary { document.mergedLibrary }

    var body: some View {
        let problems = model.problems(library: library)
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Inlay Wizard").font(.title2.bold()); Spacer(); HelpButton(topic: .inlay) }.padding([.horizontal, .top], 20)
            Text("Creates two V-carve toolpaths: a pocket in the base board and a mirrored plug for the insert board.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 4)
            Form {
                Section("Vectors") {
                    TextField("Toolpath name", text: $model.baseName)
                    HStack {
                        Text(model.shapeIDs.isEmpty ? "No closed vectors selected"
                             : "\(model.shapeIDs.count) closed vector\(model.shapeIDs.count == 1 ? "" : "s")")
                            .foregroundStyle(model.shapeIDs.isEmpty ? .orange : .primary)
                        Spacer()
                        Button("Use Current Selection") {
                            model.shapeIDs = document.selectedShapes.filter(\.isClosed).map(\.id)
                        }
                    }
                }
                Section("Tools") {
                    ToolPicker(title: "V-bit", toolID: $model.vbitID, library: library, preferred: [.vBit, .engraving])
                    OptionalToolPicker(title: "Flat area tool", toolID: $model.clearanceToolID, library: library,
                                       kinds: ClearanceToolList.kinds)
                }
                Section("Pocket (female)") {
                    LengthField("Pocket depth", value: $model.pocketDepth, units: units,
                                help: "Flat depth of the pocket below the base board's surface")
                }
                Section("Plug (male)") {
                    LengthField("Start depth", value: $model.plugStartDepth, units: units,
                                help: "The plug's V-carve starts this far below the insert board's surface")
                    LengthField("Glue gap", value: $model.glueGap, units: units, help: "Minimum space left under the plug")
                    PlugBoundaryFields(boundary: $model.plugBoundary, margin: $model.plugMargin,
                                       surfaceClearance: $model.surfaceClearance, defaultClearance: model.bottomGap,
                                       units: units)
                    Toggle("Mirror plug (cut face down)", isOn: $model.mirrorPlug)
                    Text("Gap under the plug: \(RulerTicks.label((model.bottomGap * 1000).rounded() / 1000)) \(units.abbreviation)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(Color.warningText)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Export the pocket and plug to separate files (Save All Toolpaths → one file per toolpath).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Toolpaths") {
                    document.addInlay(model)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 680)
    }
}
