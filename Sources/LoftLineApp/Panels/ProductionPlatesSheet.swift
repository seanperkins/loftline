import AppKit
import CADCore
import CAMCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Design > Layout > Production Plates…: repeats the selected design once per spreadsheet row,
/// filling `{Field}` placeholders in its text, and adds the copies to the template's toolpaths.
struct ProductionPlatesSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var options: ProductionPlateOptions
    @State private var csvText = ""
    @State private var fileName: String?
    @State private var fitColumns = true
    @State private var columns = 3
    /// Why the file could not be read or the plates not made, shown above the buttons (an alert on the
    /// document would sit under this sheet).
    @State private var failure: String?

    init(document: LoftLineDocument) {
        self.document = document
        _options = State(initialValue: ProductionPlateOptions.defaults(for: document.units))
    }

    private var ids: [UUID] { document.selectedShapes.map(\.id) }
    private var table: CSVTable { CSVTable.parse(csvText) }

    var body: some View {
        let fields = ProductionPlateCommands.fields(ids, in: document.project)
        let t = table
        let headers = Set(t.headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let unmatched = fields.filter { !headers.contains($0.lowercased()) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Production Plates").font(.title3.bold())
            Text("Select the plate design (outline and text). Type placeholders such as {Name} in its text; each spreadsheet row makes one plate with the placeholders replaced by that row's values. The first row of the spreadsheet holds the column names.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(fields.isEmpty ? "The selection has no text with a {Field} placeholder."
                 : "Fields in the design: " + fields.map { "{\($0)}" }.joined(separator: ", "))
                .font(.callout)
                .foregroundStyle(fields.isEmpty ? Color.red : Color.primary)
            HStack {
                Button("Choose CSV File…") { chooseFile() }
                if let fileName { Text(fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
            }
            TextEditor(text: $csvText)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Spreadsheet (CSV) text")
            Text(csvSummary(t, unmatched: unmatched))
                .font(.caption)
                .foregroundStyle(unmatched.isEmpty ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Toggle("As many plates across as fit the material", isOn: $fitColumns)
                if !fitColumns { IntField("Plates across", value: $columns, range: 1...500) }
                LengthField("Gap across", value: $options.gapX, units: document.units)
                LengthField("Gap between rows", value: $options.gapY, units: document.units)
                Picker("New rows go", selection: $options.rowsDown) {
                    Text("Below").tag(true)
                    Text("Above").tag(false)
                }
                Toggle("Shrink text that does not fit its plate", isOn: $options.shrinkToFit)
                if options.shrinkToFit {
                    LengthField("Margin", value: $options.margin, units: document.units,
                                help: "Clear space kept between the text and the plate's edge")
                }
                Toggle("Add the plates to the template's toolpaths", isOn: $options.includeToolpaths)
            }
            SheetErrorRow(message: failure)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Plates") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fields.isEmpty || t.rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: csvText) { _, _ in failure = nil }
    }

    private func csvSummary(_ t: CSVTable, unmatched: [String]) -> String {
        guard !t.headers.isEmpty else { return "Paste spreadsheet text above or choose a CSV file (comma, semicolon or tab separated)." }
        var s = "\(t.rows.count) row\(t.rows.count == 1 ? "" : "s"); columns: " + t.headers.joined(separator: ", ")
        if !unmatched.isEmpty {
            s += ". No column for " + unmatched.map { "{\($0)}" }.joined(separator: ", ") + " (left as typed)."
        }
        return s
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.message = "Choose a spreadsheet saved as CSV"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        failure = nil
        do {
            let data = try Data(contentsOf: url)
            csvText = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            fileName = url.lastPathComponent
        } catch {
            failure = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func run() {
        failure = nil
        var o = options
        o.columns = fitColumns ? nil : columns
        let ids = self.ids, t = table
        var p = document.project
        do {
            let r = try ProductionPlateCommands.make(ids, table: t, options: o, in: &p)
            let result = p
            document.perform("Production Plates") { $0 = result }
            document.setSelection(r.shapeIDs)
            var notes: [String] = []
            if !r.missingFields.isEmpty {
                notes.append("No column matched " + r.missingFields.map { "{\($0)}" }.joined(separator: ", ") + "; those placeholders were left as typed.")
            }
            if r.outsideMaterial > 0 {
                notes.append("\(r.outsideMaterial) plate\(r.outsideMaterial == 1 ? " reaches" : "s reach") past the material. Enlarge the material, use fewer rows, or nest them onto extra sheets (Design > Layout > Nest Parts…).")
            }
            // The notes are reported once the sheet has closed (a sheet and an alert cannot show together).
            if !notes.isEmpty {
                document.report(AlertMessage(title: r.summary, message: notes.joined(separator: "\n\n")))
            }
            dismiss()
        } catch {
            failure = "Plates not made: \(ImportService.describe(error))"
        }
    }
}
