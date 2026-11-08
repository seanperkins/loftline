import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Design > Nest Parts…: packs the selected parts (or every editable vector) onto the material.
struct NestingSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var options: NestingOptions
    @State private var running = false
    @State private var report: NestingReport?
    /// The nesting run in progress; cancelled when the sheet closes so its result is never applied.
    @State private var job: Task<Void, Never>?

    init(document: LoftLineDocument) {
        self.document = document
        _options = State(initialValue: NestingOptions.defaults(for: document.units))
    }

    /// Shapes to nest: the selection, or every editable shape when nothing is selected.
    private var targetIDs: [UUID] {
        let sel = document.selectedShapes.map(\.id)
        if !sel.isEmpty { return sel }
        return document.project.document.shapes.filter { document.project.isEditable($0) }.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nest Parts").font(.title3.bold())
            Text(document.selection.isEmpty
                 ? "Nothing is selected, so every unlocked vector is nested."
                 : "Nesting the selected vectors. Vectors inside a part move with it.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                LengthField("Part spacing", value: $options.spacing, units: document.units,
                            help: "Minimum gap between parts; use at least the cutter diameter")
                LengthField("Edge margin", value: $options.margin, units: document.units,
                            help: "Clearance between parts and the material edges")
                Picker("Rotation", selection: $options.rotationStep) {
                    Text("Keep orientation").tag(0.0)
                    Text("90° steps").tag(90.0)
                    Text("45° steps").tag(45.0)
                    Text("15° steps").tag(15.0)
                }
                IntField("Copies of each part", value: $options.quantity, range: 1...500)
                Toggle("Nest small parts inside holes", isOn: $options.nestInHoles)
                Toggle("Keep clear of other vectors", isOn: $options.avoidOtherVectors)
                Toggle("Put parts that do not fit on extra sheets", isOn: $options.overflowSheets)
                    .help("Extra sheets are layers \"Sheet 2\", \"Sheet 3\", … shown beside the material")
                if options.overflowSheets {
                    IntField("Maximum sheets", value: $options.maxSheets, range: 2...100)
                }
                Picker("Precision", selection: $options.precision) {
                    ForEach(NestPrecision.allCases) { Text($0.title).tag($0) }
                }
            }
            if let r = report {
                Label(r.summary, systemImage: r.unplaced > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(r.unplaced > 0 ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if running { ProgressView().controlSize(.small); Text("Nesting…").foregroundStyle(.secondary) }
                Spacer()
                Button(report == nil ? "Cancel" : "Done") { job?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Nest") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || targetIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onDisappear { job?.cancel() }
    }

    private func run() {
        let ids = targetIDs, opts = options, start = document.project
        running = true
        job = Task.detached(priority: .userInitiated) {
            var p = start
            let r = NestingCommands.nest(ids, options: opts, in: &p)
            let result = p
            await MainActor.run {
                // Cancelled (the sheet was closed): the user chose not to nest, so drop the result.
                guard !Task.isCancelled else { return }
                running = false
                report = r
                job = nil
                // The sheet is modal, but never overwrite a project that changed meanwhile.
                guard document.project == start else { return }
                document.perform("Nest Parts") { $0 = result }
                document.setSelection(r.placedShapeIDs)
            }
        }
    }
}
