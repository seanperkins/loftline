import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Design > Layout > Label Parts…: engraves part numbers / names on parts.
struct PartLabelsSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var options: PartLabelOptions
    @State private var fonts: [String] = []

    init(document: LoftLineDocument) {
        self.document = document
        _options = State(initialValue: PartLabelOptions.defaults(for: document.units))
    }

    private var targetIDs: [UUID] {
        let sel = document.selectedShapes.map(\.id)
        if !sel.isEmpty { return sel }
        return NestSheets.activeDocument(document.document).shapes.filter { document.project.isEditable($0) }.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Label Parts").font(.title3.bold())
            Text((document.selection.isEmpty ? "Every part on the material" : "The selected parts")
                 + " gets a label on the \"\(PartLabelCommands.layerName)\" layer, placed where the part has most room. "
                 + "Unnamed parts are named \"Part N\", and the job sheet lists them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Label", selection: $options.text) {
                    ForEach(PartLabelText.allCases) { Text($0.title).tag($0) }
                }
                LengthField("Largest text height", value: $options.maxHeight, units: document.units)
                LengthField("Smallest text height", value: $options.minHeight, units: document.units,
                            help: "Parts too small for this size are not labeled")
                Picker("Font", selection: $options.fontName) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Add a V-Carve toolpath for the labels", isOn: $options.addToolpath)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Label") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetIDs.isEmpty || options.maxHeight <= 0)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            fonts = TextOutliner.availableFontNames()
            if !fonts.contains(options.fontName) { fonts.insert(options.fontName, at: 0) }
        }
    }

    private func run() {
        let ids = targetIDs, o = options, lib = document.mergedLibrary
        var report: PartLabelReport?
        var failure: Error?
        var p = document.project
        do {
            report = try PartLabelCommands.label(ids, options: o, library: lib, in: &p)
            let result = p
            document.perform("Label Parts") { $0 = result }
        } catch {
            failure = error
        }
        // Reported before the sheet closes, so the alert waits for it (an alert cannot show over a sheet).
        if let failure {
            document.report(AlertMessage(title: "Labels not added", message: ImportService.describe(failure)))
        } else if let r = report {
            if let id = r.operationID {
                document.sidebarTab = .toolpaths
                document.selectedOperationID = id
            }
            if r.skipped > 0 {
                document.report(AlertMessage(title: "Some parts were not labeled",
                                             message: "\(r.skipped) part(s) had no room for a label of the smallest text height."))
            }
        }
        dismiss()
    }
}
