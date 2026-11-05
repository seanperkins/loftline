import AppKit
import CADCore
import CAMCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Toolpaths ▸ Preview G-code File…: simulates a .tap/.nc file from another job (or another
/// program) on this job's stock, in its own window. Preview only (toolpaths-2d round 2).
enum GCodePreviewWindow {
    private static var open: [NSWindow] = []

    @MainActor
    static func run(for document: LoftLineDocument) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["tap", "nc", "ngc", "gcode", "txt", "cnc"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a G-code file to preview on this job's material"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            document.report(AlertMessage(title: "Preview G-code", message: "Could not read \(url.lastPathComponent)."))
            return
        }
        let model = GCodePreviewModel(text: text, fileName: url.lastPathComponent, units: document.units,
                                      job: document.document.job)
        guard model.reader.moveCount > 0 else {
            document.report(AlertMessage(title: "Preview G-code", message: "\(url.lastPathComponent) has no moves LoftLine can preview."))
            return
        }
        let view = GCodePreviewView(model: model, job: document.document.job, rapidRate: document.rapidRateInDocumentUnits)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Preview: \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        open.removeAll { !$0.isVisible }
        open.append(window)
    }
}

struct GCodePreviewView: View {
    @State var model: GCodePreviewModel
    var job: JobSetup
    var rapidRate: Double

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            SimulationPreviewView(job: job, units: model.units, toolpaths: model.toolpaths, rapidRate: rapidRate,
                                  emptyMessage: "No moves to preview", documentName: model.fileName)
                .frame(minWidth: 420)
        }
    }

    private var sidebar: some View {
        Form {
            Section {
                Text(model.summary).font(.callout)
                Text("Shown on this job's material, assuming the program uses this job's XY origin and Z zero. Preview only: nothing is added to the job.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: { Text(model.fileName) }
            Section("Tools (for the simulation)") {
                ForEach($model.tools) { $entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.label).font(.callout.bold()).lineLimit(2)
                        Picker("Type", selection: $entry.tool.kind) {
                            ForEach(ToolKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        LengthField("Diameter", value: $entry.tool.diameter, units: model.units)
                        if entry.tool.kind == .vBit || entry.tool.kind == .engraving {
                            NumberField("Included angle", value: Binding(get: { entry.tool.angle ?? 60 }, set: { entry.tool.angle = $0 }), unit: "°")
                        }
                    }
                }
            }
            if !model.reader.warnings.isEmpty {
                Section("Notes (\(model.reader.warnings.count))") {
                    ForEach(Array(model.reader.warnings.prefix(50).enumerated()), id: \.offset) { _, w in
                        Text(w).font(.caption).foregroundStyle(Color.warningText)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
