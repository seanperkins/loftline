import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Validate Vectors: lists problem vectors in the selection (or the whole design), circles them
/// on the canvas and repairs what can be repaired.
struct VectorValidatorSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var includeOpen = true

    private var scopeIDs: [UUID] { document.selectedShapes.map(\.id) }

    private var issues: [VectorIssue] {
        let shapes = VectorCommands.validationScope(scopeIDs, in: document.project)
        return VectorValidator.check(shapes, tolerance: VectorCommands.tolerance(document.units), includeOpen: includeOpen)
    }

    var body: some View {
        let list = issues
        let fixable = list.filter(\.kind.isFixable).count
        VStack(alignment: .leading, spacing: 12) {
            Text("Validate Vectors").font(.title3.bold())
            Text(scopeIDs.isEmpty ? "Checking every visible vector." : "Checking the \(scopeIDs.count) selected shape\(scopeIDs.count == 1 ? "" : "s").")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Report open vectors", isOn: $includeOpen)
            if list.isEmpty {
                Label("No problems found.", systemImage: "checkmark.circle").foregroundStyle(Color.successText)
            } else {
                List {
                    ForEach(VectorIssue.Kind.allCases, id: \.self) { kind in
                        let rows = list.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            Section("\(kind.title) (\(rows.count))") {
                                ForEach(Array(rows.enumerated()), id: \.offset) { _, issue in
                                    Button { show([issue]) } label: {
                                        HStack {
                                            Text(name(of: issue.shapeID))
                                            Spacer()
                                            Text(kind.isFixable ? "fixable" : "check").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 200)
            }
            Text("Open vectors are cut on the line by profiles and ignored by pockets and V-carves. Fixing closes nearly closed vectors, deletes zero-length and duplicate vectors, removes zero-length segments and splits self-intersecting outlines into simple loops.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear Markers") { document.highlightMarkers = [] }
                    .disabled(document.highlightMarkers.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Show on Canvas") { show(list) }.disabled(list.isEmpty)
                Button("Fix \(fixable)") {
                    let found = list
                    document.perform("Fix Vectors") { VectorCommands.repair(found, in: &$0) }
                    document.highlightMarkers = []
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fixable == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func name(of id: UUID) -> String {
        guard let s = document.document.shape(id: id) else { return "Shape" }
        return s.name.isEmpty ? (s.isClosed ? "Closed vector" : "Vector") : s.name
    }

    /// Selects the affected shapes and circles the problem spots.
    private func show(_ found: [VectorIssue]) {
        document.setSelection(found.map(\.shapeID))
        document.highlightMarkers = found.compactMap(\.location)
        dismiss()
    }
}
