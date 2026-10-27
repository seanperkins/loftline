import CADCore
import CAMCore
import PostCore
import SwiftUI

/// Toolpaths > Check Toolpaths…: validator warnings and errors for every toolpath and for the
/// combined program, with a shortcut to select the offending toolpath.
struct ValidationSheet: View {
    @ObservedObject var document: LoftLineDocument
    /// Watched so that reloading the post profiles or editing a machine reaches `currentInputs`.
    @ObservedObject var catalog = PostProfileCatalog.shared
    @ObservedObject var machines = MachineCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var report: ValidationReport?
    /// What the document was made of when `report` was made.
    @State private var checkedFrom: LoftLineDocument.PostedInputs?
    @AppStorage(GCodeExporter.groupByToolKey) private var groupByTool = false
    @State private var calcTask: Task<Void, Never>?
    @State private var calculatingCount = 0
    @State private var failure: String?

    /// What a program posted now is made from: the document's inputs, the post processor and the group-by-tool preference.
    private var currentInputs: LoftLineDocument.PostedInputs { document.postedInputs.stamped(profile: document.postProfile, groupedByTool: groupByTool) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Check Toolpaths").font(.title2.bold())
                Spacer()
                Text(document.postProfile.name).foregroundStyle(.secondary)
                HelpButton(topic: .checkToolpaths)
            }
            if calcTask != nil {
                CalculationProgressView(count: calculatingCount) { calcTask?.cancel(); calcTask = nil }
            }
            SheetErrorRow(message: failure)
            if let r = report {
                summary(r)
                List {
                    ForEach(r.sections) { section in
                        Section {
                            if section.issues.isEmpty {
                                Label("No problems found", systemImage: "checkmark.seal.fill").foregroundStyle(Color.successText)
                            }
                            ForEach(Array(section.issues.enumerated()), id: \.offset) { _, issue in
                                IssueRow(issue: issue)
                            }
                        } header: {
                            HStack {
                                Text(section.title)
                                Spacer()
                                if let id = section.operationID {
                                    Button("Show") {
                                        document.sidebarTab = .toolpaths
                                        document.selectedOperationID = id
                                        dismiss()
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            } else {
                Spacer()
            }
            HStack {
                Toggle("Combined program grouped by tool", isOn: $groupByTool)
                Spacer()
                Button("Recheck") { run() }
                DismissButton("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear { run() }
        .onDisappear { calcTask?.cancel() }
        .onChange(of: currentInputs) { _, now in if now != checkedFrom { run() } }
    }

    private func summary(_ r: ValidationReport) -> some View {
        Group {
            if r.isClean {
                Label("All toolpaths passed the validator.", systemImage: "checkmark.seal.fill").foregroundStyle(Color.successText)
            } else {
                Label("\(r.errorCount) error(s) and \(r.warningCount) warning(s). Errors must be fixed before cutting; warnings are worth a look.",
                      systemImage: r.errorCount > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.errorCount > 0 ? .red : .orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func run() {
        failure = nil
        calcTask?.cancel()
        calcTask = nil
        let targets = document.outputProject.operations.filter { $0.setup.isEnabled }.map(\.id)
        let stale = targets.filter { document.isStale($0) }
        guard !stale.isEmpty else { check(); return }
        report = nil   // the last report is of toolpaths that are being replaced
        calculatingCount = stale.count
        calcTask = Task { @MainActor in
            // Checks only when nothing is stale: a result computed before a later change is calculated again.
            let fresh = await document.calculateUntilFresh(targets: targets)
            guard !Task.isCancelled else { return }
            calcTask = nil
            if fresh { check() } else { failure = "The project changed while it was being calculated. Export again." }
        }
    }

    private func check() {
        checkedFrom = currentInputs
        report = ValidationReport.make(project: document.outputProject, results: document.results,
                                       profile: document.postProfile, groupByTool: groupByTool)
    }
}

struct IssueRow: View {
    var issue: GCodeIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
            Text(issue.message).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let l = issue.line { Text("line \(l)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}
