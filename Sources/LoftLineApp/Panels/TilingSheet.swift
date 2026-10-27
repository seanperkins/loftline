import AppKit
import CADCore
import CAMCore
import PostCore
import SwiftUI

/// Toolpaths > Save Tiled G-code…: splits a job larger than the machine into tiles, one
/// program each, zeroed at the tile's lower-left corner on the material.
struct TilingSheet: View {
    @ObservedObject var document: LoftLineDocument
    /// Watched so that reloading the post profiles or editing a machine reaches `currentInputs`.
    @ObservedObject var catalog = PostProfileCatalog.shared
    @ObservedObject var machines = MachineCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GCodeExporter.groupByToolKey) private var groupByTool = false
    @State private var settings = TilingSettings(tileWidth: 60, tileHeight: 96)
    @State private var files: [TiledExport.File] = []
    /// What the document was made of when `files` was posted; Save waits while the document has moved on.
    @State private var postedFrom: LoftLineDocument.PostedInputs?
    @State private var calcTask: Task<Void, Never>?
    @State private var calculatingCount = 0
    @State private var confirmErrors = false
    @State private var replaceRequest: ReplaceRequest?
    /// Why the last save failed, shown above the buttons (an alert on the document would sit under this sheet).
    @State private var failure: String?

    /// What a program posted now is made from: the document's inputs, the post processor and the group-by-tool preference.
    private var currentInputs: LoftLineDocument.PostedInputs { document.postedInputs.stamped(profile: document.postProfile, groupedByTool: groupByTool) }

    /// Validator errors, which "Save Anyway" may override.
    private var hasErrors: Bool { files.contains { $0.result.hasErrors } }
    /// A tile set with a program missing is never written (see `GCodeFileSet`), so the save waits.
    private var hasUnposted: Bool { files.contains { $0.result.text == nil } }

    var body: some View {
        let u = document.units
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Tiled G-code").font(.title2.bold())
            Text("Each tile is cut with the material moved so the tile is under the machine. Zero X and Y at the "
                 + "tile's corner on the material (given in each file's header). Cuts that cross a seam stop at it "
                 + "and continue in the next tile; overlap re-cuts a band on both sides of each seam.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                LengthField("Largest tile width (X)", value: $settings.tileWidth, units: u)
                LengthField("Largest tile height (Y)", value: $settings.tileHeight, units: u)
                LengthField("Overlap at seams", value: $settings.overlap, units: u)
            }
            let ignored = ToolpathTiling.axesIgnoringOverlap(settings)
            if ignored.x || ignored.y {
                Label("An overlap of half a tile or more is ignored" + (ignored.x && ignored.y ? "." : ignored.x ? " along X." : " along Y."),
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if calcTask != nil {
                CalculationProgressView(count: calculatingCount) { calcTask?.cancel(); calcTask = nil }
            } else if files.isEmpty {
                Label("There are no calculated, enabled toolpaths to save.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningText)
            } else {
                List(Array(files.enumerated()), id: \.offset) { _, f in row(f) }
            }
            SheetErrorRow(message: failure)
            HStack {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { if hasErrors { confirmErrors = true } else { save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || hasUnposted || postedFrom != currentInputs)
                    .help(hasUnposted ? "A tile could not be generated; fix it before saving, so no tile is left out." : "")
                    // On the button, not the sheet: a view carries one alert, and the sheet has the validator's.
                    .replaceFilesAlert($replaceRequest) { r in finishSaving(from: r.postedFrom) { try r.set.write(to: r.directory, replacing: r.names) } }
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .onAppear {
            settings = TiledExport.defaultSettings(profile: document.postProfile, units: document.units)
            run()
        }
        .onDisappear { calcTask?.cancel() }
        .onChange(of: settings) { _, _ in if calcTask == nil { post() } }
        .onChange(of: currentInputs) { _, now in if now != postedFrom { run() } }
        .alert("The validator reported errors", isPresented: $confirmErrors) {
            Button("Save Anyway", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some tiles have validator errors. Running them may damage the machine or the work.")
        }
    }

    private func row(_ f: TiledExport.File) -> some View {
        let errors = f.result.issues.filter { $0.severity == .error }.count
        let warnings = f.result.issues.count - errors
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "square.split.2x2")
                Text(f.fileName).font(.body.monospaced())
                Spacer()
                Text("\(f.tile.toolpaths.count) toolpath\(f.tile.toolpaths.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Text("Zero XY at material X \(RulerTicks.label(f.tile.region.min.x)) Y \(RulerTicks.label(f.tile.region.min.y)); "
                 + "tile \(RulerTicks.label(f.tile.region.width)) x \(RulerTicks.label(f.tile.region.height)) \(document.units.abbreviation)")
                .font(.caption).foregroundStyle(.secondary)
            if let e = f.result.errorMessage {
                Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Color.errorText)
            } else if errors + warnings > 0 {
                Label("\(errors) error(s), \(warnings) warning(s)", systemImage: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(errors > 0 ? .red : .orange)
                    .help(f.result.issues.map(\.message).joined(separator: "\n"))
            } else {
                Label("No problems found", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Color.successText)
            }
        }
    }

    private func run() {
        calcTask?.cancel()
        calcTask = nil
        let stale = document.outputProject.operations.filter { $0.setup.isEnabled && document.isStale($0.id) }.map(\.id)
        guard !stale.isEmpty else { post(); return }
        files = []
        calculatingCount = stale.count
        calcTask = Task { @MainActor in
            let done = await document.calculateAndWait(stale)
            guard done, !Task.isCancelled else { return }
            calcTask = nil
            post()
        }
    }

    private func post() {
        failure = nil
        postedFrom = currentInputs
        guard settings.tileWidth > 0, settings.tileHeight > 0 else { files = []; return }
        files = Self.tileFiles(document: document, groupByTool: groupByTool, settings: settings)
    }

    /// The tile programs as the sheet posts them: the document's post, machine and tool notices come first in every tile,
    /// as they do in the Export G-code sheet.
    static func tileFiles(document: LoftLineDocument, groupByTool: Bool, settings: TilingSettings) -> [TiledExport.File] {
        TiledExport.files(project: document.outputProject, results: document.results, profile: document.postProfile,
                          groupByTool: groupByTool, settings: settings, extraIssues: document.postProfileIssues)
    }

    private func save() {
        failure = nil
        let panel = PanelRunner.makeOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder for \(files.count) tile programs"
        let set = GCodeFileSet(tiles: files)
        let from = postedFrom
        PanelRunner.present(panel) { response in
            guard response == .OK, let dir = panel.url else { return }
            if set.needsReplaceConfirmation(in: dir) {
                replaceRequest = ReplaceRequest(set: set, directory: dir, postedFrom: from)
            } else {
                finishSaving(from: from) { try set.write(to: dir) }
            }
        }
    }

    /// Writes the whole set (or nothing), then closes the sheet. A failure stays in the sheet, above
    /// its buttons (an alert on the document would sit under the sheet), so another folder can be chosen.
    /// `inputs` is what the tiles were posted from when the save began: a set posted before an edit made
    /// while the panel or the replace question was up is not written.
    private func finishSaving(from inputs: LoftLineDocument.PostedInputs?, _ write: () throws -> Void) {
        guard inputs == currentInputs else { failure = LoftLineDocument.PostedInputs.changedWhileSaving; return }
        do {
            try write()
            dismiss()
        } catch {
            failure = "Could not save G-code: \(error.localizedDescription)"
        }
    }
}
