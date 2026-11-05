import SwiftUI
import LoftLineKit

/// Shown by the export/check sheets while stale toolpaths are recalculated in the background.
struct CalculationProgressView: View {
    var count: Int
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Calculating \(count) toolpath\(count == 1 ? "" : "s")…")
            Spacer()
            Button("Stop", action: cancel)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
