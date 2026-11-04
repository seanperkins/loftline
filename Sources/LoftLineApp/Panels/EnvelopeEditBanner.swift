import CADCore
import SwiftUI
import LoftLineKit

/// Floating bar over the canvas while envelope corners are being dragged.
struct EnvelopeEditBanner: View {
    @ObservedObject var document: LoftLineDocument
    @State private var showNumbers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "perspective").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Distort: drag the corners").font(.callout.bold())
                    Text("Corners snap like nodes (⌘ disables) · Return applies · Esc cancels")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(showNumbers ? "Hide Values" : "Values…") { showNumbers.toggle() }
                Button("Reset") { document.envelopeEdit?.offsets = [Vec2](repeating: .zero, count: 4) }
                Button("Cancel") { document.cancelEnvelopeEdit() }
                Button("Apply") { document.applyEnvelopeEdit() }.buttonStyle(.borderedProminent)
            }
            if showNumbers, document.envelopeEdit != nil {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        GridRow {
                            Text(EnvelopeEdit.cornerNames[i]).font(.caption)
                            LengthField("X", value: offset(i, \.x), units: document.units)
                            LengthField("Y", value: offset(i, \.y), units: document.units)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2)
    }

    /// Corner offset component `i` (moving the corner relative to the original box).
    private func offset(_ i: Int, _ k: WritableKeyPath<Vec2, Double>) -> Binding<Double> {
        Binding(get: { document.envelopeEdit?.offsets[i][keyPath: k] ?? 0 },
                set: { document.envelopeEdit?.offsets[i][keyPath: k] = $0 })
    }
}
