import CADCore
import CAMCore
import PostCore
import SwiftUI
import LoftLineKit

/// Text for the status bar, kept apart from the view so it can be tested.
enum StatusReadout {
    /// "X 12.5  Y 3 in": the unit comes last because it applies to both numbers.
    static func cursor(_ p: Vec2, units: LengthUnit) -> String {
        func rounded(_ v: Double) -> String { RulerTicks.label((v * 1000).rounded() / 1000) }
        return "X \(rounded(p.x))  Y \(rounded(p.y)) \(units.abbreviation)"
    }

    /// The post processor's name is enough when it belongs to the machine (its name already says which
    /// machine it is for); otherwise both are shown so a mismatch is visible.
    static func machineAndPost(machine: MachineDefinition?, post: PostProfile) -> String {
        guard let machine, !machine.supports(postID: post.id) else { return post.name }
        return "\(machine.name) · \(post.name)"
    }
}

/// One line under the canvas. The job facts on the left give way, longest group first, as the pane
/// narrows; the selection count and cursor position on the right keep a fixed width so they never wrap
/// or make the left side jump while the pointer moves.
struct StatusBar: View {
    @ObservedObject var document: LoftLineDocument

    private enum Detail { case full, withoutMachine, compact }

    var body: some View {
        HStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                facts(.full)
                facts(.withoutMachine)
                facts(.compact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            readouts
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func facts(_ detail: Detail) -> some View {
        HStack(spacing: 14) {
            // Z0 and the origin are what a wrong setup crashes a bit on, so they outlast the material size.
            if detail != .compact { Text(GCodeExporter.materialDescription(document.document)) }
            let zero = document.outputProject.document.job.zZero
            Text("Z0: " + (detail == .compact ? zero.shortName : zero.displayName))
            Text("Origin: " + document.document.job.xyOrigin.displayName)
            if document.document.isMultiSheet { Text("Sheet: " + document.document.currentSheetName).bold() }
            if document.isTwoSided { Text("Side: " + document.activeSide.displayName).bold() }
            if detail == .full {
                Button { document.sheet = .jobSetup } label: {
                    Text(StatusReadout.machineAndPost(machine: document.machine, post: document.postProfile))
                }
                .buttonStyle(.plain)
                .help("Machine and post processor. Click to change them in Job Setup.")
                .accessibilityHint("Opens Job Setup")
            }
        }
        .fixedSize()
    }

    private var readouts: some View {
        HStack(spacing: 14) {
            Text(document.selection.isEmpty ? "" : "\(document.selection.count) selected")
                .frame(minWidth: 60, alignment: .trailing)
            Text(document.cursorPosition.map { StatusReadout.cursor($0, units: document.units) } ?? "")
                .monospacedDigit()
                .frame(minWidth: 110, alignment: .trailing)
        }
        .fixedSize()
    }
}
