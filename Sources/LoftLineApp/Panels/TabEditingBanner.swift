import SwiftUI
import LoftLineKit

/// Floating hint over the canvas while the tab editor is active.
struct TabEditingBanner: View {
    var name: String
    var count: Int
    var done: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Editing tabs: \(name) (\(count) tab\(count == 1 ? "" : "s"))").font(.callout.bold())
                Text("Click a vector to add a tab · drag a tab to move it · ⌥-click a tab to delete it")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Done", action: done).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2)
    }
}
