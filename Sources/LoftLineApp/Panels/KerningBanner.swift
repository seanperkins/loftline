import SwiftUI
import LoftLineKit

/// Floating bar over the canvas while letters of a text object are being kerned.
struct KerningBanner: View {
    @ObservedObject var document: LoftLineDocument

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.cursor.ibeam").foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kerning: \(document.kerningShape?.text?.string.replacingOccurrences(of: "\n", with: " ") ?? "")")
                    .font(.callout.bold()).lineLimit(1)
                Text("Drag a letter · Shift-drag moves the rest of the line too · arrows nudge the clicked letter (Shift: grid step)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset Letters") { document.resetKerning() }
                .disabled(document.kerningShape?.text?.letterAdjustments == nil)
            Button("Done") { document.endKerning() }.buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 2)
    }
}
