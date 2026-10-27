import AppKit
import CADCore
import CAMCore
import PostCore
import SwiftUI
import UniformTypeIdentifiers

/// Export G-code: choose scope and machine, see validator warnings, then save.
struct ExportGCodeSheet: View {
    @ObservedObject var document: LoftLineDocument
    @ObservedObject var catalog = PostProfileCatalog.shared
    @ObservedObject var machines = MachineCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State var scope: GCodeExportScope
    @AppStorage(GCodeExporter.groupByToolKey) private var groupByTool = false
    @State private var profileID: String = ""
    /// The id shown on open; the project keeps its own reference unless the user picks another.
    @State private var initialProfileID: String = ""
    @State private var result: GCodeExportResult?
    /// What the document was made of when `result` was posted; Save waits while the document has moved on.
    @State private var postedFrom: LoftLineDocument.PostedInputs?
    @State private var confirmErrors = false
    @State private var calcTask: Task<Void, Never>?
    @State private var calculatingCount = 0
    /// Why the last Save failed, shown above the buttons (an alert on the document would sit under this sheet).
    @State private var failure: String?

    /// What a program posted now is made from: the document's inputs, the post processor and the group-by-tool preference.
    private var currentInputs: LoftLineDocument.PostedInputs { document.postedInputs.stamped(profile: profile, groupedByTool: groupByTool) }

    /// The chosen post with the job's machine limits applied.
    private var profile: PostProfile { document.effectiveProfile(id: profileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Export G-code").font(.title2.bold()); Spacer(); HelpButton(topic: .exportGCode) }
            Form {
                Picker("Toolpaths", selection: $scope) {
                    Text("All enabled toolpaths").tag(GCodeExportScope.all)
                    ForEach(document.outputProject.operations) { op in
                        Text(op.setup.name).tag(GCodeExportScope.operation(op.id))
                    }
                }
                if scope == .all {
                    Toggle("Group by tool (fewest tool changes)", isOn: $groupByTool)
                }
                LabeledContent("Machine", value: document.machine?.name ?? "Custom (post limits)")
                PostProfilePicker(title: "Post processor", selection: $profileID, machine: document.machine,
                                  carried: document.carriedPostNotInstalled)
                if document.isTwoSided {
                    LabeledContent("Side", value: document.activeSide.displayName + " (switch in the Design menu)")
                }
                LabeledContent("Z zero", value: document.outputProject.document.job.zZero.displayName)
                LabeledContent("XY origin", value: document.document.job.xyOrigin.displayName)
                if let cut = result?.deepestCut {
                    LabeledContent("Deepest cut", value: cut.text(units: document.units))
                }
            }
            // Natural height: a fixed one clipped the last rows (and a two-sided job adds a row).
            .formStyle(.columns)
            if calcTask != nil {
                CalculationProgressView(count: calculatingCount) { stopCalculating() }
            }
            issuesView
            SheetErrorRow(message: failure)
            HStack {
                Button("Refresh") { run() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save…") { if result?.hasErrors == true { confirmErrors = true } else { save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result?.text == nil || calcTask != nil || postedFrom != currentInputs)
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear {
            profileID = document.postProfile.id
            initialProfileID = profileID
            run()
        }
        .onDisappear { calcTask?.cancel() }
        .onChange(of: scope) { _, _ in run() }
        .onChange(of: currentInputs) { _, now in if now != postedFrom { run() } }
        .alert("The validator reported errors", isPresented: $confirmErrors) {
            Button("Save Anyway", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running this program may damage the machine or the work. Save anyway?")
        }
    }

    @ViewBuilder private var issuesView: some View {
        if let r = result {
            if let e = r.errorMessage {
                Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(Color.errorText)
            }
            if r.issues.isEmpty && r.errorMessage == nil {
                Label("No problems found in \(r.toolpathCount) toolpath(s).", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.successText)
            }
            if !r.issues.isEmpty {
                List(Array(r.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.displayText, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                }
                .frame(minHeight: 80, maxHeight: 140)
            }
            if let text = r.text {
                ScrollView {
                    Text(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.3))
            }
        } else if calcTask == nil {
            Label("Calculation stopped. Press Refresh to calculate and post.", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }

    private func targetOperations() -> [UUID] {
        switch scope {
        case .all: return document.outputProject.operations.filter(\.setup.isEnabled).map(\.id)
        case .operation(let id): return [id]
        }
    }

    /// Recalculates stale toolpaths in the background (exported toolpaths must reflect the
    /// current parameters), then posts.
    private func run() {
        failure = nil
        calcTask?.cancel()
        calcTask = nil
        let targets = targetOperations()
        let stale = targets.filter { document.isStale($0) }
        guard !stale.isEmpty else { post(); return }
        result = nil
        calculatingCount = stale.count
        calcTask = Task { @MainActor in
            // Posts only when nothing is stale: a result computed before a later change is calculated again.
            let fresh = await document.calculateUntilFresh(targets: targets)
            guard !Task.isCancelled else { return }
            calcTask = nil
            if fresh { post() } else { failure = "The project changed while it was being calculated. Export again." }
        }
    }

    private func stopCalculating() {
        calcTask?.cancel()
        calcTask = nil
    }

    private func post() {
        let tps = GCodeExporter.toolpaths(scope: scope, operations: document.outputProject.operations,
                                          results: document.results, groupByTool: groupByTool)
        let missing = GCodeExporter.missingOperationIssues(targetOperations().compactMap { document.operation($0) },
                                                           results: document.results)
        var r = GCodeExporter.export(project: document.outputProject(for: scope), toolpaths: tps, profile: profile,
                                     jobName: document.document.name)
        // The project's own post's notices apply only while the program is posted with that post.
        r.issues.insert(contentsOf: document.postProfileIssues(includingPost: profileID == initialProfileID) + missing, at: 0)
        result = r
        postedFrom = currentInputs
    }

    private func save() {
        guard let text = result?.text else { return }
        failure = nil
        let inputs = postedFrom
        let panel = PanelRunner.makeSavePanel()
        var opName: String?
        if case .operation(let id) = scope { opName = document.operation(id)?.setup.name }
        panel.nameFieldStringValue = SavePanelName.suggested(
            GCodeExporter.suggestedFileName(jobName: document.document.name, operationName: opName, profile: profile),
            allowedExtension: profile.fileExtension)
        if let t = UTType(filenameExtension: profile.fileExtension) { panel.allowedContentTypes = [t] }
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        PanelRunner.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            guard inputs == currentInputs else { failure = LoftLineDocument.PostedInputs.changedWhileSaving; return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                if profileID != initialProfileID { document.setPostProfile(profileID) }
                postedFrom = currentInputs  // the post just written already used that profile
                dismiss()
            } catch {
                failure = "Could not save G-code: \(error.localizedDescription)"
            }
        }
    }
}

/// Offset dialog for the selection.
struct OffsetSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var distance: Double
    @State private var outward = true
    @State private var sharp = false

    init(document: LoftLineDocument) {
        self.document = document
        _distance = State(initialValue: document.units == .inch ? 0.125 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Offset Vectors").font(.title3.bold()); Spacer(); HelpButton(topic: .transforms) }
            Form {
                LengthField("Distance", value: $distance, units: document.units)
                Picker("Direction", selection: $outward) {
                    Text("Outwards").tag(true)
                    Text("Inwards").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Sharp corners", isOn: $sharp)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Offset") {
                    let ids = document.selectedShapes.map(\.id)
                    let d = outward ? abs(distance) : -abs(distance)
                    let s = sharp
                    var newIDs: [UUID] = []
                    document.perform("Offset") { newIDs = DesignCommands.offset(ids, distance: d, sharpCorners: s, in: &$0) }
                    if !newIDs.isEmpty { document.setSelection(newIDs) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(distance == 0 || document.selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
