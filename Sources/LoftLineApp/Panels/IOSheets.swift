import AppKit
import CADCore
import CAMCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Dialogs added by the io workstream, shown through `DocumentSheet.io`.
enum IOSheet: Equatable {
    case modelParts(ModelPartsForm)
    /// File > Job Notes…; `openedWithFile` = shown automatically as the file opened.
    case jobNotes(openedWithFile: Bool)
    /// File > Clipart…
    case clipart
    /// An SVG that does not state its size: which pixels per inch it was drawn at.
    case svgScale(SVGScaleRequest)

    var id: String {
        switch self {
        case .modelParts(let f): return "parts-\(f.id)"
        case .svgScale(let r): return "svg-\(r.id)"
        case .jobNotes: return "notes"
        case .clipart: return "clipart"
        }
    }
}

struct IOSheetHost: View {
    @ObservedObject var document: LoftLineDocument
    var sheet: IOSheet

    var body: some View {
        switch sheet {
        case .modelParts(let form): ModelPartsSheet(document: document, form: form)
        case .jobNotes(let opened): JobNotesSheet(document: document, openedWithFile: opened)
        case .clipart: ClipartBrowserSheet(document: document)
        case .svgScale(let request): SVGScaleSheet(document: document, request: request)
        }
    }
}

// MARK: Job notes

struct JobNotesSheet: View {
    @ObservedObject var document: LoftLineDocument
    var openedWithFile: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var showOnOpen: Bool

    init(document: LoftLineDocument, openedWithFile: Bool) {
        self.document = document
        self.openedWithFile = openedWithFile
        _text = State(initialValue: document.document.jobNotes)
        _showOnOpen = State(initialValue: document.document.showsNotesOnOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(openedWithFile ? "Notes for \(document.document.name)" : "Job Notes").font(.title2.bold())
            Text("Saved with the file and printed on the job sheet: material, fixturing, which side goes up, anything the next person at the machine should know.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 200)
                .border(Color.secondary.opacity(0.4))
                .accessibilityLabel("Job notes")
            Toggle("Show these notes when the file is opened", isOn: $showOnOpen)
            HStack {
                Spacer()
                if openedWithFile {
                    DismissButton("Close") { save(); dismiss() }
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }

    /// Writes only real changes, so just reading the notes never dirties the document.
    private func save() {
        let d = document.document
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != d.jobNotes || showOnOpen != d.showsNotesOnOpen else { return }
        document.setJobNotes(text, showOnOpen: showOnOpen)
    }
}

// MARK: Import 3D model as 2D parts

extension LoftLineDocument {
    /// File > Import 3D Model as 2D Parts…
    func runModelPartsPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = (ModelPartsForm.allowedExtensions + ["skp"]).compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a 3D model (COLLADA .dae from SketchUp, STL or OBJ) to cut as flat parts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            sheet = .io(.modelParts(try ModelPartsForm.read(data: data, fileName: url.lastPathComponent, units: units)))
        } catch {
            report(AlertMessage(title: "Import", message: "\(url.lastPathComponent): \(ImportService.describe(error))"))
        }
    }

    /// Imports an SVG at the scale the user confirmed. Failures and notes are reported with `report(_:)`:
    /// the sheet is still up when this runs.
    func importSVG(_ request: SVGScaleRequest, pixelsPerInch: Double) {
        do {
            let outcome = try commitImport(data: request.data, fileName: request.fileName, svgPixelsPerInch: pixelsPerInch)
            if !outcome.shapeIDs.isEmpty {
                setSelection(outcome.shapeIDs)
                sidebarTab = .design
                requestCanvas(.fit)
            } else if !outcome.imageIDs.isEmpty {
                requestCanvas(.fit)
            }
            if !outcome.warnings.isEmpty {
                report(AlertMessage(title: "Import", message: outcome.warnings.map { "\(request.fileName): \($0)" }.joined(separator: "\n")))
            }
        } catch {
            report(AlertMessage(title: "Import", message: "\(request.fileName): \(ImportService.describe(error))"))
        }
    }

    func importModelParts(_ form: ModelPartsForm) {
        var outcome = ImportOutcome()
        perform("Import Parts") { outcome = form.apply(to: &$0) }
        if !outcome.shapeIDs.isEmpty {
            setSelection(outcome.shapeIDs)
            sidebarTab = .design
            requestCanvas(.fit)
        }
        if !outcome.warnings.isEmpty {
            report(AlertMessage(title: "Import Parts", message: outcome.warnings.joined(separator: "\n")))
        }
    }
}

struct ModelPartsSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var form: ModelPartsForm
    @State private var summary: [(String, Int)] = []

    init(document: LoftLineDocument, form: ModelPartsForm) {
        self.document = document
        _form = State(initialValue: form)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import 3D Model as 2D Parts").font(.title2.bold())
            Text("\(form.fileName): \(form.parts.count) part\(form.parts.count == 1 ? "" : "s"). Each part becomes a closed outline (with any through-holes) to cut with a Profile toolpath.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Outline", selection: $form.view) {
                    ForEach(MeshParts.View.allCases, id: \.self) { Text(ModelPartsForm.viewTitle($0)).tag($0) }
                }
                LengthField("Gap between parts", value: $form.gap, units: document.units)
                    .disabled(form.view != .flat)
                Toggle("One layer per part thickness", isOn: $form.layerPerThickness)
                    .disabled(form.view != .flat)
            }
            if !summary.isEmpty {
                Text("Thicknesses").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary, id: \.0) { row in Text("\(row.0): \(row.1) part\(row.1 == 1 ? "" : "s")") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            Text("Pockets, grooves and other features inside a part are not converted; only its outline and holes that go right through.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    document.importModelParts(form)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.gap < 0)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { summary = form.thicknessSummary(units: document.units) }
    }
}
