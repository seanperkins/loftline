import AppKit
import CADCore
import CAMCore
import PostCore
import SwiftUI
import UniformTypeIdentifiers

/// Save All Toolpaths: one combined program (grouped by tool or in list order), one file per
/// toolpath, or one file per tool. Shows each file's tools, time and validator result.
struct SaveAllToolpathsSheet: View {
    @ObservedObject var document: LoftLineDocument
    @ObservedObject var catalog = PostProfileCatalog.shared
    @ObservedObject var machines = MachineCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode: SaveAllMode = .oneFileInOrder
    @State private var profileID = ""
    /// The id shown on open; the project keeps its own reference unless the user picks another.
    @State private var initialProfileID = ""
    @State private var posted: [(file: PlannedGCodeFile, result: GCodeExportResult)] = []
    /// What the document was made of when `posted` was made; Save waits while the document has moved on.
    @State private var postedFrom: LoftLineDocument.PostedInputs?
    @State private var confirmErrors = false
    /// A folder save waiting for the user to agree to replace the files already there.
    @State private var replaceRequest: ReplaceRequest?
    @State private var calcTask: Task<Void, Never>?
    @State private var calculatingCount = 0
    /// Why the last save failed, shown above the buttons (an alert on the document would sit under this sheet).
    @State private var failure: String?

    /// What the files posted now are made from: the document's inputs and the post processor.
    private var currentInputs: LoftLineDocument.PostedInputs { document.postedInputs.stamped(profile: profile) }

    /// The chosen post with the job's machine limits applied.
    private var profile: PostProfile { document.effectiveProfile(id: profileID) }
    /// Validator errors, which "Save Anyway" may override.
    private var hasErrors: Bool { posted.contains { $0.result.hasErrors } }
    /// A set with a program missing is never written (see `GCodeFileSet`), so the save waits.
    private var hasUnposted: Bool { posted.contains { $0.result.text == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Save All Toolpaths").font(.title2.bold()); Spacer(); HelpButton(topic: .saveAllToolpaths) }
            Form {
                Picker("Output", selection: $mode) {
                    ForEach(SaveAllMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Machine", value: document.machine?.name ?? "Custom (post limits)")
                PostProfilePicker(title: "Post processor", selection: $profileID, machine: document.machine)
            }
            .formStyle(.grouped)
            .frame(height: 190)
            if calcTask != nil {
                CalculationProgressView(count: calculatingCount) { calcTask?.cancel(); calcTask = nil }
                Spacer()
            } else if posted.isEmpty {
                Label("There are no calculated, enabled toolpaths to save.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warningText)
            } else {
                List(Array(posted.enumerated()), id: \.offset) { _, item in fileRow(item.file, item.result) }
            }
            SheetErrorRow(message: failure)
            HStack {
                Button("Check Toolpaths…") { document.sheet = .validation }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode.isSingleFile ? "Save…" : "Choose Folder…") {
                    if hasErrors { confirmErrors = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(posted.isEmpty || hasUnposted || postedFrom != currentInputs)
                .help(hasUnposted ? "A program could not be generated; fix it before saving, so no file is left out." : "")
                // On the button, not the sheet: a view carries one alert, and the sheet has the validator's.
                .replaceFilesAlert($replaceRequest) { r in finishSaving(from: r.postedFrom) { try r.set.write(to: r.directory, replacing: r.names) } }
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
        .onAppear {
            profileID = document.postProfile.id
            initialProfileID = profileID
            run()
        }
        .onDisappear { calcTask?.cancel() }
        .onChange(of: mode) { _, _ in run() }
        .onChange(of: currentInputs) { _, now in if now != postedFrom { run() } }
        .alert("The validator reported errors", isPresented: $confirmErrors) {
            Button("Save Anyway", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some programs have validator errors. Running them may damage the machine or the work.")
        }
    }

    private func fileRow(_ file: PlannedGCodeFile, _ r: GCodeExportResult) -> some View {
        let loads = JobSummary.sequence(of: file.toolpaths)
        let secs = document.estimateSeconds(file.toolpaths)
        let errors = r.issues.filter { $0.severity == .error }.count
        let warnings = r.issues.count - errors
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "doc.text")
                Text(file.fileName).font(.body.monospaced())
                Spacer()
                Text(ToolpathCalculator.formatDuration(secs)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(loads.map { "T\($0.number) \($0.name)" }.joined(separator: " → "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let cut = r.deepestCut {
                Text("Deepest cut " + cut.text(units: document.units)).font(.caption).foregroundStyle(.secondary)
            }
            if let e = r.errorMessage {
                Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Color.errorText)
            } else if errors + warnings > 0 {
                Label("\(errors) error(s), \(warnings) warning(s)", systemImage: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(errors > 0 ? .red : .orange)
            } else {
                Label("No problems found", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(Color.successText)
            }
        }
        .padding(.vertical, 2)
    }

    private func run() {
        failure = nil
        calcTask?.cancel()
        calcTask = nil
        let targets = document.outputProject.operations.filter { $0.setup.isEnabled }.map(\.id)
        let stale = targets.filter { document.isStale($0) }
        guard !stale.isEmpty else { post(); return }
        posted = []
        calculatingCount = stale.count
        calcTask = Task { @MainActor in
            // Posts only when nothing is stale: a result computed before a later change is calculated again.
            let fresh = await document.calculateUntilFresh(targets: targets)
            guard !Task.isCancelled else { return }
            calcTask = nil
            if fresh { post() } else { failure = "The project changed while it was being calculated. Export again." }
        }
    }

    private func post() {
        let files = GCodeBatchExport.plan(mode: mode, operations: document.outputProject.operations,
                                          results: document.results, jobName: document.document.name, profile: profile)
        posted = GCodeBatchExport.post(files, project: document.outputProject, profile: profile, jobName: document.document.name)
        let missing = document.postProfileIssues
            + GCodeExporter.missingOperationIssues(document.outputProject.operations, results: document.results)
        if !missing.isEmpty {
            posted = posted.map { item in
                var r = item.result
                r.issues.insert(contentsOf: missing, at: 0)
                return (item.file, r)
            }
        }
        postedFrom = currentInputs
    }

    private func save() {
        failure = nil
        let from = postedFrom
        if mode.isSingleFile {
            guard let item = posted.first, let text = item.result.text else { return }
            let panel = PanelRunner.makeSavePanel()
            panel.nameFieldStringValue = SavePanelName.suggested(item.file.fileName, allowedExtension: profile.fileExtension)
            if let t = UTType(filenameExtension: profile.fileExtension) { panel.allowedContentTypes = [t] }
            panel.allowsOtherFileTypes = true
            panel.canCreateDirectories = true
            PanelRunner.present(panel) { response in
                guard response == .OK, let url = panel.url else { return }
                finishSaving(from: from) { try text.write(to: url, atomically: true, encoding: .utf8) }
            }
        } else {
            let panel = PanelRunner.makeOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose a folder for \(posted.count) G-code files"
            let set = GCodeFileSet(posted: posted)
            PanelRunner.present(panel) { response in
                guard response == .OK, let dir = panel.url else { return }
                if set.needsReplaceConfirmation(in: dir) {
                    replaceRequest = ReplaceRequest(set: set, directory: dir, postedFrom: from)
                } else {
                    finishSaving(from: from) { try set.write(to: dir) }
                }
            }
        }
    }

    /// Runs the write chosen in the panel, then remembers the post and closes the sheet. A failure
    /// stays in the sheet, above its buttons (an alert on the document would sit under the sheet),
    /// so another file or folder can be chosen. `inputs` is what the program was posted from when the
    /// save began: the panel and the replace question are modal to this window only, so a program
    /// posted before an edit made meanwhile is not written.
    private func finishSaving(from inputs: LoftLineDocument.PostedInputs?, _ write: () throws -> Void) {
        guard inputs == currentInputs else { failure = LoftLineDocument.PostedInputs.changedWhileSaving; return }
        do {
            try write()
            if profileID != initialProfileID { document.setPostProfile(profileID) }
            postedFrom = currentInputs  // the post just written already used that profile
            dismiss()
        } catch {
            failure = "Could not save G-code: \(error.localizedDescription)"
        }
    }
}
